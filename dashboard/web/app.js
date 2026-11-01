
"use strict";

const { useState, useEffect, useCallback } = React;
const html = htm.bind(React.createElement);

const NETWORK_MESSAGE =
  "Cannot reach the dashboard server. It may have stopped, or the laptop was asleep. Restart it with .\\run-local.ps1 (a new browser tab opens with a fresh sign-in).";

const SIGNED_OUT_MESSAGE =
  "You are signed out (the dashboard was restarted). Use the new tab that opens when it starts.";

// ---------------------------------------------------------------- helpers

function safeUrl(url) {
  return typeof url === "string" && url.startsWith("https://") ? url : null;
}

function formatTime(value) {
  if (!value) return "-";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "-" : date.toLocaleString();
}

function formatDuration(seconds) {
  if (seconds === null || seconds === undefined) return "-";
  if (seconds < 60) return seconds + "s";
  return Math.floor(seconds / 60) + "m " + (seconds % 60) + "s";
}

function shortDigest(value) {
  if (!value) return "-";
  return String(value).replace("sha256:", "").slice(0, 12);
}

function percent(value) {
  return value === null || value === undefined ? "-" : value + "%";
}

// General status classification.
// Event-specific rollback classification is handled separately below.

function kindOf(text) {
  const value = String(text || "").toLowerCase();

  if ([
    "healthy",
    "succeeded",
    "success",
    "promoted",
    "deployed",
    "passed",
    "resolved",
    "closed"
  ].includes(value)) return "good";

  if ([
    "failed",
    "unreachable",
    "rollback_failed",
    "aborted_before_traffic",
    "failed_before_deploy",
    "failed_before_traffic",
    "fired"
  ].includes(value)) return "bad";

  if ([
    "release in progress",
    "inprogress",
    "partiallysucceeded",
    "promoted_with_cleanup_warning",
    "new",
    "acknowledged",
    "rollback",
    "rolled_back",
    "noop_already_live"
  ].includes(value)) return "warn";

  return "muted";
}

// Classify deployment outcome using BOTH event name and outcome.
// This prevents successful rollback operations and recovered deployment
// incidents from being confused with failed rollback operations.

function deploymentOutcome(event) {
  const name = String(event.name || "").toLowerCase();
  const outcome = String(event.outcome || "").toLowerCase();

  if (name === "rollback") {
    if (outcome === "rolled_back") {
      return { label: "Recovered", kind: "good" };
    }

    if (outcome === "noop_already_live" || outcome === "already_live") {
      return { label: "No action needed", kind: "muted" };
    }

    if (outcome === "rollback_failed" || outcome === "failed") {
      return { label: "Failed", kind: "bad" };
    }
  }

  if (name === "deployment" && outcome === "rolled_back") {
    return { label: "Recovered", kind: "warn" };
  }

  if (outcome === "promoted" || outcome === "deployed") {
    return { label: "Promoted", kind: "good" };
  }

  if (outcome === "promoted_with_cleanup_warning") {
    return { label: "Promoted (cleanup warning)", kind: "warn" };
  }

  if ([
    "failed",
    "rollback_failed",
    "aborted_before_traffic",
    "failed_before_deploy",
    "failed_before_traffic"
  ].includes(outcome)) {
    return { label: "Failed", kind: "bad" };
  }

  if ([
    "noop_already_live",
    "already_live",
    "already_deployed"
  ].includes(outcome)) {
    return { label: "No action needed", kind: "muted" };
  }

  return {
    label: event.outcome || "-",
    kind: kindOf(outcome)
  };
}

// One place that talks to the dashboard server and turns every kind
// of failure into a clear message.

async function fetchJson(path, options) {
  let response;

  try {
    response = await fetch(
      path,
      Object.assign(
        {
          credentials: "same-origin",
          cache: "no-store",
          headers: { Accept: "application/json" }
        },
        options || {}
      )
    );
  } catch (error) {
    throw new Error(NETWORK_MESSAGE);
  }

  const body = await response.json().catch(() => ({}));

  if (response.status === 401) {
    throw new Error(SIGNED_OUT_MESSAGE);
  }

  if (!response.ok) {
    throw new Error(body.error || "Request failed (" + response.status + ")");
  }

  return body;
}

function useApi(path, intervalMs) {
  const [state, setState] = useState({
    data: null,
    error: null,
    loading: true,
    updated: null
  });

  const load = useCallback(async () => {
    try {
      const body = await fetchJson(path);

      setState({
        data: body,
        error: null,
        loading: false,
        updated: new Date()
      });
    } catch (error) {
      setState((old) => ({
        data: old.data,
        error: error.message,
        loading: false,
        updated: old.updated
      }));
    }
  }, [path]);

  useEffect(() => {
    load();

    if (!intervalMs) return undefined;

    const timer = setInterval(load, intervalMs);

    return () => clearInterval(timer);
  }, [load, intervalMs]);

  return { ...state, reload: load };
}

// ---------------------------------------------------------------- small components

function Badge({ kind, children }) {
  return html`<span className=${"badge " + (kind || "muted")}>${children}</span>`;
}

function Ext({ href, children }) {
  const url = safeUrl(href);

  if (!url) {
    return html`<span className="muted">${children}</span>`;
  }

  return html`<a href=${url} target="_blank" rel="noopener noreferrer">${children}</a>`;
}

function Panel({ title, state, wide, children }) {
  const stale = state.error && state.data;

  return html`
    <section className=${"panel" + (wide ? " wide" : "")}>
      <h2>${title}</h2>
      ${state.error
        ? html`<p className="error">${state.error}${stale ? " Showing the last data received at " + formatTime(state.updated) + "." : ""}</p>`
        : null}
      ${state.data
        ? children
        : state.loading
          ? html`<p className="muted">Loading...</p>`
          : null}
    </section>`;
}

function Kpi({ label, value, hint }) {
  return html`
    <div className="kpi">
      <div className="label">${label}</div>
      <div className="value">${value}</div>
      <div className="hint">${hint || ""}</div>
    </div>`;
}

// Checks every 10 seconds that the dashboard server itself is alive.

function ServerBanner({ onRecovered }) {
  const [down, setDown] = useState(false);

  useEffect(() => {
    let failures = 0;
    let wasDown = false;

    async function check() {
      try {
        const response = await fetch("/healthz", { cache: "no-store" });

        if (!response.ok) throw new Error("not ok");

        failures = 0;

        if (wasDown) {
          wasDown = false;
          setDown(false);
          onRecovered();
        }
      } catch (error) {
        failures += 1;

        if (failures >= 2) {
          wasDown = true;
          setDown(true);
        }
      }
    }

    check();

    const timer = setInterval(check, 10000);

    return () => clearInterval(timer);
  }, []);

  if (!down) return null;

  return html`
    <div className="notice bad">
      The dashboard server is not reachable, so the data below may be old.
      If its PowerShell window shows a title starting with "Select", press Esc in it.
      If the window is closed, start it again with .\\run-local.ps1.
    </div>`;
}

// ---------------------------------------------------------------- environment cards

function EnvironmentCard({ env }) {
  const live = env.live || {};
  const traffic = env.traffic || [];

  return html`
    <article className="card">
      <header>
        <h3>${env.label} <span className="muted">(${env.app})</span></h3>
        <${Badge} kind=${kindOf(env.status)}>${env.status}<//>
      </header>

      ${(env.errors || []).map((message) =>
        html`<p className="error" key=${message}>${message}</p>`
      )}

      <dl>
        <dt>Commit</dt><dd className="mono">${live.gitSha || "-"}</dd>
        <dt>Version</dt><dd>${live.version || "-"}</dd>
        <dt>Environment name</dt><dd>${live.environment || "-"}</dd>
        <dt>Serving revision</dt><dd className="mono">${live.revision || env.latestRevision || "-"}</dd>
        <dt>Image</dt><dd className="mono">${env.imageTag ? "tag " + env.imageTag : env.imageDigest ? "digest " + shortDigest(env.imageDigest) : "-"}</dd>
        <dt>Health check</dt><dd>${live.healthOk === undefined ? "-" : live.healthOk ? "OK in " + live.healthMs + " ms" : "FAILED " + (live.error || "")}</dd>
        <dt>Last checked</dt><dd>${formatTime(live.checkedAt)}</dd>
        <dt>URL</dt><dd><${Ext} href=${env.url}>${env.url || "-"}<//></dd>
      </dl>

      <div>
        <div className="muted">Traffic split</div>
        <div className="traffic">
          ${traffic.map((item, index) =>
            html`<span key=${index} title=${item.revision + " " + item.weight + "%"} style=${{ width: item.weight + "%" }}></span>`
          )}
        </div>
        <div className="muted mono">
          ${traffic.map((item) => item.revision + " " + item.weight + "%").join("  |  ") || "-"}
        </div>
      </div>

      <div className="links">
        <${Ext} href=${env.links.app}>Azure Portal<//>
        <${Ext} href=${env.links.metrics}>Metrics<//>
        <${Ext} href=${env.links.logs}>Logs<//>
        <${Ext} href=${env.links.applicationInsights}>Application Insights<//>
        <${Ext} href=${env.links.workspace}>Log Analytics<//>
      </div>
    </article>`;
}

// ---------------------------------------------------------------- tables

function PipelinesTable({ runs }) {
  return html`
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Pipeline</th>
            <th>Run</th>
            <th>Status</th>
            <th>Branch</th>
            <th>Commit</th>
            <th>Duration</th>
            <th>Started</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${runs.map((run) => html`
            <tr key=${run.id}>
              <td>${run.pipeline}</td>
              <td>${run.number}</td>
              <td><${Badge} kind=${kindOf(run.state)}>${run.state}<//></td>
              <td>${run.branch}</td>
              <td className="mono">${run.shortSha}</td>
              <td>${formatDuration(run.durationSeconds)}</td>
              <td>${formatTime(run.startedAt || run.queuedAt)}</td>
              <td><${Ext} href=${run.url}>Open<//></td>
            </tr>`)}
        </tbody>
      </table>
    </div>`;
}

function DeploymentsTable({ events }) {
  const [filter, setFilter] = useState("all");

  const shown = events.filter(
    (event) => filter === "all" || event.env === filter
  );

  return html`
    <div>
      <div className="tabs">
        ${["all", "staging", "production"].map((name) => html`
          <button
            key=${name}
            className=${filter === name ? "active" : ""}
            onClick=${() => setFilter(name)}
          >${name}</button>`)}
      </div>

      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Time</th>
              <th>Environment</th>
              <th>Event</th>
              <th>Outcome</th>
              <th>Commit</th>
              <th>Revision</th>
              <th>Digest</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            ${shown.map((event, index) => {
              const display = deploymentOutcome(event);

              return html`
                <tr key=${event.time + index}>
                  <td>${formatTime(event.time)}</td>
                  <td>${event.env}</td>
                  <td>${event.name}</td>
                  <td>
                    <${Badge} kind=${display.kind}>${display.label}<//>
                  </td>
                  <td className="mono">${event.shortSha || "-"}</td>
                  <td className="mono">${event.revision || "-"}</td>
                  <td className="mono">${shortDigest(event.imageDigest)}</td>
                  <td><${Ext} href=${event.runUrl}>Run<//></td>
                </tr>`;
            })}
          </tbody>
        </table>
      </div>

      ${shown.length === 0
        ? html`<p className="muted">No deployment events yet.</p>`
        : null}
    </div>`;
}

// ---------------------------------------------------------------- security, SLO, alerts

function SecurityBody({ data }) {
  return html`
    <div>
      <h3 className="muted">Latest scan of the deployed image</h3>

      ${data.latestScans.length === 0
        ? html`<p className="muted">No scan results yet. Run a deployment after Milestone 8 to record one.</p>`
        : html`
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Environment</th>
                  <th>Gate</th>
                  <th>Critical</th>
                  <th>High</th>
                  <th>Commit</th>
                  <th>Scanner</th>
                  <th>SBOM hash</th>
                  <th>Scanned</th>
                </tr>
              </thead>
              <tbody>
                ${data.latestScans.map((scan) => html`
                  <tr key=${scan.env}>
                    <td>${scan.label}</td>
                    <td><${Badge} kind=${kindOf(scan.gateResult)}>${scan.gateResult}<//></td>
                    <td>${scan.criticalCount === null ? "-" : scan.criticalCount}</td>
                    <td>${scan.highCount === null ? "-" : scan.highCount}</td>
                    <td className="mono">${scan.shortSha}</td>
                    <td>${scan.trivyVersion || "-"}</td>
                    <td className="mono">${shortDigest(scan.sbomSha256)}</td>
                    <td>${formatTime(scan.time)}</td>
                  </tr>`)}
              </tbody>
            </table>
          </div>`}

      <h3 className="muted">Failed CI runs (releases that never reached deployment)</h3>

      ${data.blockedReleases.length === 0
        ? html`<p className="muted">None in the recent history.</p>`
        : html`
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>When</th>
                  <th>Run</th>
                  <th>Commit</th>
                  <th>Failed step</th>
                  <th>Kind</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                ${data.blockedReleases.map((run) => html`
                  <tr key=${run.id}>
                    <td>${formatTime(run.finishedAt)}</td>
                    <td>${run.number}</td>
                    <td className="mono">${run.shortSha}</td>
                    <td>${run.failedStep}</td>
                    <td>
                      <${Badge} kind=${run.category === "security gate" ? "bad" : "warn"}>
                        ${run.category}
                      <//>
                    </td>
                    <td><${Ext} href=${run.url}>Open<//></td>
                  </tr>`)}
              </tbody>
            </table>
          </div>`}
    </div>`;
}

function SloBody({ data }) {
  return html`
    <div className="grid two">
      ${data.items.map((item) => {
        const slo = item.requestSlo;

        return html`
          <div className="card" key=${item.env}>
            <header>
              <h3>${item.label}</h3>
              ${slo
                ? html`<${Badge} kind=${slo.sloMet ? "good" : "bad"}>${slo.sloMet ? "SLO met" : "SLO missed"}<//>`
                : html`<${Badge} kind="muted">no data<//>`}
            </header>

            ${item.errors.map((message) =>
              html`<p className="error" key=${message}>${message}</p>`
            )}

            <dl>
              <dt>Requests (30 days)</dt><dd>${slo ? slo.total : "-"}</dd>
              <dt>Request success</dt><dd>${slo ? percent(slo.availabilitySli) : "-"} <span className="muted">target ${data.targets.requestSuccessPercent}%</span></dd>
              <dt>Under 500 ms</dt><dd>${slo ? percent(slo.latencySli) : "-"} <span className="muted">target ${data.targets.latencyUnder500msPercent}%</span></dd>
              <dt>Error budget used</dt><dd>${slo ? percent(slo.budgetUsedPercent) : "-"}</dd>
              <dt>Availability test</dt><dd>${item.availability ? percent(item.availability.percent) + " (" + item.availability.passed + "/" + item.availability.total + ")" : "-"} <span className="muted">target ${data.targets.availabilityPercent}%</span></dd>
            </dl>
          </div>`;
      })}
    </div>`;
}

function AlertsBody({ data }) {
  if (data.alerts.length === 0) {
    return html`<p className="muted">No DeployFlow alerts in the last 7 days.</p>`;
  }

  return html`
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Rule</th>
            <th>Severity</th>
            <th>Condition</th>
            <th>Alert state</th>
            <th>Target</th>
            <th>Fired</th>
            <th>Changed</th>
          </tr>
        </thead>
        <tbody>
          ${data.alerts.map((alert, index) => html`
            <tr key=${alert.rule + index}>
              <td>${alert.rule}</td>
              <td>${alert.severity}</td>
              <td><${Badge} kind=${kindOf(alert.condition)}>${alert.condition}<//></td>
              <td>${alert.state}</td>
              <td>${alert.target}</td>
              <td>${formatTime(alert.firedAt)}</td>
              <td>${formatTime(alert.changedAt)}</td>
            </tr>`)}
        </tbody>
      </table>
    </div>`;
}

// ---------------------------------------------------------------- actions

function ActionsPanel({ me }) {
  const [target, setTarget] = useState("");
  const [reason, setReason] = useState("");
  const [message, setMessage] = useState(null);
  const [busy, setBusy] = useState(false);

  async function send(path, body, question) {
    if (!window.confirm(question)) return;

    setBusy(true);
    setMessage(null);

    try {
      const data = await fetchJson(path, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-DeployFlow-CSRF": "1"
        },
        body: JSON.stringify(body)
      });

      setMessage({
        kind: "good",
        text: data.message,
        url: data.url
      });
    } catch (error) {
      setMessage({
        kind: "bad",
        text: error.message
      });
    } finally {
      setBusy(false);
    }
  }

  const isAdmin = me && me.role === "admin";
  const enabled = me && me.actionsEnabled;

  return html`
    <section className="panel">
      <h2>Actions</h2>

      ${!isAdmin
        ? html`<p className="muted">You have read-only access. Only administrators can start actions.</p>`
        : null}

      ${isAdmin && !enabled
        ? html`<p className="muted">Actions are switched off on this dashboard.</p>`
        : null}

      <p className="muted">
        Actions start the real Azure DevOps pipelines.
        Production still waits for the approval check in Azure DevOps.
      </p>

      <form className="action" onSubmit=${(event) => event.preventDefault()}>
        <strong>Request a rollback of production</strong>

        <input
          placeholder="Revision to roll back to (empty = previous revision)"
          value=${target}
          onChange=${(event) => setTarget(event.target.value)}
          disabled=${!isAdmin || !enabled}
        />

        <input
          placeholder="Reason (3-100 characters, no quotes)"
          value=${reason}
          onChange=${(event) => setReason(event.target.value)}
          disabled=${!isAdmin || !enabled}
        />

        <button
          className="btn danger"
          disabled=${!isAdmin || !enabled || busy}
          onClick=${() =>
            send(
              "/api/actions/rollback",
              { targetRevision: target, reason: reason },
              "Queue the production rollback pipeline?"
            )}
        >Request rollback</button>
      </form>

      <form className="action" onSubmit=${(event) => event.preventDefault()}>
        <strong>Request a deployment of the latest CI build</strong>

        <button
          className="btn primary"
          disabled=${!isAdmin || !enabled || busy}
          onClick=${() =>
            send(
              "/api/actions/deploy",
              { confirm: true },
              "Queue the CD pipeline for the latest successful CI build?"
            )}
        >Request deployment</button>
      </form>

      ${message
        ? html`
          <div className=${"notice " + message.kind}>
            ${message.text}
            ${message.url
              ? html`<${Ext} href=${message.url}>Open the run<//>`
              : null}
          </div>`
        : null}
    </section>`;
}

// ---------------------------------------------------------------- the page

function App() {
  const me = useApi("/api/me", 0);
  const environments = useApi("/api/environments", 60000);
  const pipelines = useApi("/api/pipelines", 60000);
  const deployments = useApi("/api/deployments", 120000);
  const security = useApi("/api/security", 300000);
  const slo = useApi("/api/slo", 300000);
  const alerts = useApi("/api/alerts", 120000);

  const deploymentStats = deployments.data
    ? deployments.data.stats.all
    : null;

  const pipelineStats = pipelines.data
    ? pipelines.data.stats
    : null;

  const ci = pipelineStats
    ? pipelineStats.byPipeline["deployflow-ci"]
    : null;

  const cd = pipelineStats
    ? pipelineStats.byPipeline["deployflow-cd"]
    : null;

  function refreshAll() {
    [me, environments, pipelines, deployments, security, slo, alerts]
      .forEach((item) => item.reload());
  }

  return html`
    <div>
      <div className="topbar">
        <div>
          <h1>DeployFlow</h1>
          <div className="sub">
            Release platform dashboard: live data from Azure and Azure DevOps
          </div>
        </div>

        <div className="right">
          ${me.data
            ? html`
              <span>${me.data.user}</span>
              <${Badge} kind=${me.data.role === "admin" ? "warn" : "muted"}>
                ${me.data.role}
              <//>`
            : null}

          <button className="btn" onClick=${refreshAll}>Refresh</button>
        </div>
      </div>

      <main>
        <${ServerBanner} onRecovered=${refreshAll} />

        ${me.error
          ? html`<p className="error">${me.error}</p>`
          : null}

        ${environments.error && environments.data
          ? html`<p className="error">${environments.error} Showing the last data received at ${formatTime(environments.updated)}.</p>`
          : null}

        <div className="grid cards">
          ${environments.data
            ? environments.data.environments.map((env) =>
                html`<${EnvironmentCard} env=${env} key=${env.key} />`
              )
            : html`
              <section className="panel">
                <h2>Environments</h2>
                ${environments.error
                  ? html`<p className="error">${environments.error}</p>`
                  : html`<p className="muted">Loading... (the first request can take a few seconds while the apps wake up)</p>`}
              </section>`}
        </div>

        <div className="grid kpis">
          <${Kpi}
            label="Deployment success rate"
            value=${deploymentStats ? percent(deploymentStats.successRatePercent) : "-"}
            hint="last 30 days"
          />

          <${Kpi}
            label="Deployments"
            value=${deploymentStats ? deploymentStats.succeeded + " ok / " + deploymentStats.failed + " failed" : "-"}
            hint="staging and production"
          />

          <${Kpi}
            label="Rollbacks"
            value=${deploymentStats ? deploymentStats.rollbacks : "-"}
            hint=${deploymentStats ? deploymentStats.automaticRollbacks + " automatic, " + deploymentStats.manualRollbacks + " manual" : ""}
          />

          <${Kpi}
            label="Pipeline success rate"
            value=${pipelineStats ? percent(pipelineStats.overallSuccessRatePercent) : "-"}
            hint=${pipelineStats ? pipelineStats.overallSucceeded + " ok / " + pipelineStats.overallFailed + " failed" : ""}
          />

          <${Kpi}
            label="Average CI duration"
            value=${ci ? formatDuration(ci.averageDurationSeconds) : "-"}
            hint="build, scan, push"
          />

          <${Kpi}
            label="Average CD duration"
            value=${cd ? formatDuration(cd.averageDurationSeconds) : "-"}
            hint="includes time waiting for approval"
          />
        </div>

        <div className="grid">
          <${Panel} title="Pipeline runs" state=${pipelines} wide=${true}>
            ${pipelines.data
              ? html`
                <div>
                  ${pipelines.data.missingPipelines.length
                    ? html`<p className="error">Pipelines not found: ${pipelines.data.missingPipelines.join(", ")}</p>`
                    : null}
                  <${PipelinesTable} runs=${pipelines.data.runs} />
                </div>`
              : null}
          <//>

          <${Panel} title="Deployment history" state=${deployments} wide=${true}>
            ${deployments.data
              ? html`
                <div>
                  ${deployments.data.problems.map((message) =>
                    html`<p className="error" key=${message}>${message}</p>`
                  )}
                  <${DeploymentsTable} events=${deployments.data.events} />
                </div>`
              : null}
          <//>

          <${Panel}
            title="Deployment incidents and failures"
            state=${deployments}
            wide=${true}
          >
            ${deployments.data
              ? html`
                ${deployments.data.failures.length === 0
                  ? html`<p className="muted">No failed deployments or recovered incidents in the last 30 days.</p>`
                  : html`<${DeploymentsTable} events=${deployments.data.failures} />`}
              `
              : null}
          <//>

          <${Panel}
            title="Security: scan results and policy failures"
            state=${security}
            wide=${true}
          >
            ${security.data
              ? html`<${SecurityBody} data=${security.data} />`
              : null}
          <//>

          <${Panel}
            title="Service level objectives and error budget"
            state=${slo}
            wide=${true}
          >
            ${slo.data
              ? html`<${SloBody} data=${slo.data} />`
              : null}
          <//>

          <${Panel}
            title="Alerts (last 7 days)"
            state=${alerts}
            wide=${true}
          >
            ${alerts.data
              ? html`<${AlertsBody} data=${alerts.data} />`
              : null}
          <//>
        </div>

        <div className="grid two" style=${{ marginTop: "16px" }}>
          <${ActionsPanel} me=${me.data} />
        </div>

        <footer>
          Data comes live from Azure Container Apps, Log Analytics,
          Azure Monitor and Azure DevOps. Nothing on this page is hard-coded.
        </footer>
      </main>
    </div>`;
}

ReactDOM.createRoot(document.getElementById("root")).render(
  html`<${App} />`
);
