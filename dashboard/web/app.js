"use strict";

const { useState, useEffect, useCallback } = React;
const html = htm.bind(React.createElement);

const NETWORK_MESSAGE =
  "Cannot reach the dashboard server. It may have stopped, or the laptop was asleep. Restart it with .\\run-local.ps1 (a new browser tab opens with a fresh sign-in).";

const SIGNED_OUT_MESSAGE =
  "You are signed out (the dashboard was restarted). Use the new tab that opens when it starts.";

// --------------------------------------------------
// Helpers
// --------------------------------------------------

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

function kindOf(text) {
  const value = String(text || "").toLowerCase();

  if ([
    "healthy", "succeeded", "success", "promoted",
    "deployed", "passed", "resolved", "closed"
  ].includes(value)) return "good";

  if ([
    "failed", "unreachable", "rollback_failed",
    "aborted_before_traffic", "failed_before_deploy",
    "failed_before_traffic", "fired"
  ].includes(value)) return "bad";

  if ([
    "release in progress", "inprogress", "partiallysucceeded",
    "promoted_with_cleanup_warning", "new", "acknowledged",
    "rollback", "rolled_back", "noop_already_live"
  ].includes(value)) return "warn";

  return "muted";
}

function deploymentOutcome(event) {
  const name = String(event.name || "").toLowerCase();
  const outcome = String(event.outcome || "").toLowerCase();

  if (name === "rollback") {
    if (outcome === "rolled_back") {
      return { label: "Recovered (manual rollback)", kind: "good" };
    }

    if (outcome === "noop_already_live" || outcome === "already_live") {
      return { label: "No action needed", kind: "muted" };
    }

    if (outcome === "rollback_failed" || outcome === "failed") {
      return { label: "Rollback failed", kind: "bad" };
    }
  }

  if (name === "deployment" && outcome === "rolled_back") {
    return { label: "Rejected, recovered automatically", kind: "warn" };
  }

  if (outcome === "promoted" || outcome === "deployed") {
    return { label: "Promoted", kind: "good" };
  }

  if (outcome === "promoted_with_cleanup_warning") {
    return { label: "Promoted (cleanup warning)", kind: "warn" };
  }

  if ([
    "failed", "rollback_failed", "aborted_before_traffic",
    "failed_before_deploy", "failed_before_traffic"
  ].includes(outcome)) {
    return { label: "Failed", kind: "bad" };
  }

  if ([
    "noop_already_live", "already_live", "already_deployed"
  ].includes(outcome)) {
    return { label: "No action needed", kind: "muted" };
  }

  return {
    label: event.outcome || "-",
    kind: kindOf(outcome)
  };
}

// --------------------------------------------------
// API
// --------------------------------------------------

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

// --------------------------------------------------
// Basic components
// --------------------------------------------------

function Badge({ kind, children }) {
  return html`
    <span className=${"badge " + (kind || "muted")}>
      ${children}
    </span>`;
}

function Ext({ href, children }) {
  const url = safeUrl(href);

  if (!url) {
    return html`<span className="muted">${children}</span>`;
  }

  return html`
    <a href=${url} target="_blank" rel="noopener noreferrer">
      ${children}
    </a>`;
}

function Panel({ title, state, wide, children, id }) {
  const stale = state.error && state.data;

  return html`
    <section
      id=${id || undefined}
      className=${"panel" + (wide ? " wide" : "")}
    >
      <h2>${title}</h2>

      ${state.error
        ? html`
          <p className="error">
            ${state.error}
            ${stale
              ? " Showing the last data received at " +
                formatTime(state.updated) + "."
              : ""}
          </p>`
        : null}

      ${state.data
        ? children
        : state.loading
          ? html`
            <p className="muted">
              Loading... (the first load can take up to a minute while the apps wake up)
            </p>`
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

// --------------------------------------------------
// Circular charts
// --------------------------------------------------

function DonutChart({
  title,
  value,
  percent: percentage,
  color = "#7657ff",
  subtitle = ""
}) {
  const amount = Math.max(
    0,
    Math.min(100, Number(percentage) || 0)
  );

  return html`
    <article className="visual-card donut-card">

      <div className="visual-card-header">
        <div>
          <h3>${title}</h3>
          <p>${subtitle}</p>
        </div>

        <span
          className="chart-indicator"
          style=${{ background: color }}
        ></span>
      </div>

      <div className="donut-container">
        <div
          className="donut-chart"
          style=${{
            "--chart-color": color,
            "--chart-percent": amount + "%"
          }}
        >
          <div className="donut-center">
            <strong>${value}</strong>
            <span>${amount.toFixed(1)}%</span>
          </div>
        </div>
      </div>

      <div className="donut-footer">
        <span>
          <i style=${{ background: color }}></i>
          Success rate
        </span>

        <strong>${amount.toFixed(1)}%</strong>
      </div>
    </article>`;
}

// --------------------------------------------------
// Animated bar chart
// --------------------------------------------------

function MiniBarChart({ title, subtitle, items }) {
  const maxValue = Math.max(
    1,
    ...items.map(item => Number(item.value) || 0)
  );

  return html`
    <article className="visual-card">

      <div className="visual-card-header">
        <div>
          <h3>${title}</h3>
          <p>${subtitle}</p>
        </div>

        <span className="chart-icon">▥</span>
      </div>

      <div className="mini-chart">
        ${items.map((item, index) => html`
          <div className="mini-chart-row" key=${item.label}>

            <div className="mini-chart-label">
              <span>${item.label}</span>
              <strong>${item.value}</strong>
            </div>

            <div className="mini-chart-track">
              <div
                className="mini-chart-fill"
                style=${{
                  "--bar-width":
                    ((Number(item.value) || 0) / maxValue * 100) + "%",
                  "--bar-color": item.color || "#7657ff",
                  "--bar-delay": (index * 100) + "ms"
                }}
              ></div>
            </div>

          </div>
        `)}
      </div>

    </article>`;
}

// --------------------------------------------------
// Server monitoring
// --------------------------------------------------

function ServerBanner({ onRecovered }) {
  const [down, setDown] = useState(false);

  useEffect(() => {
    let failures = 0;
    let wasDown = false;

    async function check() {
      try {
        const response = await fetch("/healthz", {
          cache: "no-store"
        });

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
      If its PowerShell window shows a title starting with "Select",
      press Esc in it. If the window is closed, start it again with
      .\\run-local.ps1.
    </div>`;
}

// --------------------------------------------------
// Environment cards
// --------------------------------------------------

function EnvironmentCard({ env }) {
  const live = env.live || {};
  const traffic = env.traffic || [];

  const infoMissing =
    live.healthOk !== undefined && live.infoOk === false;

  const unknown =
    "unknown (/api/info did not answer" +
    (live.infoError ? ": " + live.infoError : "") +
    ")";

  const servingRevision =
    env.servingRevision ||
    live.revision ||
    env.latestRevision ||
    "-";

  return html`
    <article className="card">

      <header>
        <h3>
          ${env.label}
          <span className="muted">(${env.app})</span>
        </h3>

        <${Badge} kind=${kindOf(env.status)}>
          ${env.status}
        <//>
      </header>

      ${(env.errors || []).map((message) =>
        html`<p className="error" key=${message}>${message}</p>`
      )}

      ${(env.notes || []).map((message) =>
        html`<p className="muted" key=${message}>Note: ${message}</p>`
      )}

      <dl>
        <dt>Commit</dt>
        <dd className="mono">
          ${live.gitSha || (infoMissing ? unknown : "-")}
        </dd>

        <dt>Version</dt>
        <dd>${live.version || (infoMissing ? unknown : "-")}</dd>

        <dt>Environment name</dt>
        <dd>${live.environment || (infoMissing ? unknown : "-")}</dd>

        <dt>Serving revision</dt>
        <dd className="mono">${servingRevision}</dd>

        <dt>Image</dt>
        <dd className="mono">
          ${env.imageTag
            ? "tag " + env.imageTag
            : env.imageDigest
              ? "digest " + shortDigest(env.imageDigest)
              : "-"}
        </dd>

        <dt>Health check</dt>
        <dd>
          ${live.healthOk === undefined
            ? "-"
            : live.healthOk
              ? "OK in " + live.healthMs + " ms"
              : "FAILED " + (live.error || "")}
        </dd>

        <dt>Last checked</dt>
        <dd>${formatTime(live.checkedAt)}</dd>

        <dt>URL</dt>
        <dd>
          <${Ext} href=${env.url}>${env.url || "-"}<//>
        </dd>
      </dl>

      <div>
        <div className="muted">Traffic split</div>

        <div className="traffic">
          ${traffic.map((item, index) => html`
            <span
              key=${index}
              title=${item.revision + " " + item.weight + "%"}
              style=${{ width: item.weight + "%" }}
            ></span>
          `)}
        </div>

        <div className="muted mono">
          ${traffic.map(
            item => item.revision + " " + item.weight + "%"
          ).join("  |  ") || "-"}
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

// --------------------------------------------------
// Pipeline table
// --------------------------------------------------

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
          ${runs.map(run => html`
            <tr key=${run.id}>
              <td>${run.pipeline}</td>
              <td>${run.number}</td>

              <td>
                <${Badge} kind=${kindOf(run.state)}>
                  ${run.state}
                <//>
              </td>

              <td>${run.branch}</td>
              <td className="mono">${run.shortSha}</td>
              <td>${formatDuration(run.durationSeconds)}</td>
              <td>${formatTime(run.startedAt || run.queuedAt)}</td>
              <td><${Ext} href=${run.url}>Open<//></td>
            </tr>
          `)}
        </tbody>

      </table>
    </div>`;
}

// --------------------------------------------------
// Deployment table
// --------------------------------------------------

function DeploymentsTable({ events }) {
  const [filter, setFilter] = useState("all");

  const shown = events.filter(
    event => filter === "all" || event.env === filter
  );

  return html`
    <div>

      <div className="tabs">
        ${["all", "staging", "production"].map(name => html`
          <button
            key=${name}
            className=${filter === name ? "active" : ""}
            onClick=${() => setFilter(name)}
          >
            ${name}
          </button>
        `)}
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
                    <${Badge} kind=${display.kind}>
                      ${display.label}
                    <//>
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

// --------------------------------------------------
// Security
// --------------------------------------------------

function SecurityBody({ data }) {
  const deployedImages = data.deployedImages || [];
  const scanHistory = data.scanHistory || [];
  const blockedReleases = data.blockedReleases || [];

  return html`
    <div>

      <h3 className="muted">
        Is the image that is running now the image that was scanned?
      </h3>

      <div className="table-wrap">
        <table>

          <thead>
            <tr>
              <th>Environment</th>
              <th>Result</th>
              <th>Live image digest</th>
              <th>Scan gate</th>
              <th>Critical</th>
              <th>High</th>
              <th>Commit</th>
              <th>Scanner</th>
              <th>SBOM hash</th>
              <th>Scanned</th>
            </tr>
          </thead>

          <tbody>
            ${deployedImages.map(item => {
              const scan = item.deployedImageScan;
              const verified = item.verification === "MATCH";

              return html`
                <tr key=${item.env}>
                  <td>${item.label}</td>

                  <td>
                    <${Badge} kind=${verified ? "good" : "warn"}>
                      ${verified
                        ? "Verified"
                        : "No scan evidence for this image"}
                    <//>

                    ${verified && item.matchedBy
                      ? html`
                        <div className="muted">
                          matched by ${item.matchedBy}
                        </div>`
                      : null}

                    ${(item.errors || []).map(message =>
                      html`
                        <div className="error" key=${message}>
                          ${message}
                        </div>`
                    )}
                  </td>

                  <td className="mono">
                    ${shortDigest(item.liveImageDigest)}
                  </td>

                  <td>
                    ${scan
                      ? html`
                        <${Badge} kind=${kindOf(scan.gateResult)}>
                          ${scan.gateResult}
                        <//>`
                      : "-"}
                  </td>

                  <td>
                    ${scan && scan.criticalCount !== null
                      ? scan.criticalCount
                      : "-"}
                  </td>

                  <td>
                    ${scan && scan.highCount !== null
                      ? scan.highCount
                      : "-"}
                  </td>

                  <td className="mono">
                    ${scan ? scan.shortSha || "-" : "-"}
                  </td>

                  <td>${scan ? scan.trivyVersion || "-" : "-"}</td>

                  <td className="mono">
                    ${scan ? shortDigest(scan.sbomSha256) : "-"}
                  </td>

                  <td>${scan ? formatTime(scan.time) : "-"}</td>
                </tr>`;
            })}
          </tbody>

        </table>
      </div>

      <p className="muted">
        Verified means a recorded security scan belongs to the exact image
        digest that is receiving traffic right now. "No scan evidence"
        means the image was released before scan results were recorded,
        or no record could be matched. It does not mean the scan failed:
        read the Scan gate column.
      </p>

      <h3 className="muted">Security scan history</h3>

      ${scanHistory.length === 0
        ? html`<p className="muted">No security scan records found.</p>`
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
                  <th>Image digest</th>
                  <th>SBOM hash</th>
                  <th>Scanned</th>
                </tr>
              </thead>

              <tbody>
                ${scanHistory.map((scan, index) => html`
                  <tr key=${scan.env + scan.time + index}>
                    <td>${scan.label}</td>

                    <td>
                      <${Badge} kind=${kindOf(scan.gateResult)}>
                        ${scan.gateResult}
                      <//>
                    </td>

                    <td>
                      ${scan.criticalCount === null
                        ? "-"
                        : scan.criticalCount}
                    </td>

                    <td>
                      ${scan.highCount === null
                        ? "-"
                        : scan.highCount}
                    </td>

                    <td className="mono">${scan.shortSha || "-"}</td>
                    <td>${scan.trivyVersion || "-"}</td>

                    <td className="mono">
                      ${shortDigest(
                        scan.scannedImageDigest || scan.deployedImageDigest
                      )}
                    </td>

                    <td className="mono">
                      ${shortDigest(scan.sbomSha256)}
                    </td>

                    <td>${formatTime(scan.time)}</td>
                  </tr>
                `)}
              </tbody>
            </table>
          </div>`}

      <h3 className="muted">
        Failed CI runs (releases that never reached deployment)
      </h3>

      ${blockedReleases.length === 0
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
                ${blockedReleases.map(run => html`
                  <tr key=${run.id}>
                    <td>${formatTime(run.finishedAt)}</td>
                    <td>${run.number}</td>
                    <td className="mono">${run.shortSha}</td>
                    <td>${run.failedStep}</td>

                    <td>
                      <${Badge}
                        kind=${run.category === "security gate" ? "bad" : "warn"}
                      >
                        ${run.category}
                      <//>
                    </td>

                    <td><${Ext} href=${run.url}>Open<//></td>
                  </tr>
                `)}
              </tbody>
            </table>
          </div>`}

    </div>`;
}

// --------------------------------------------------
// SLO
// --------------------------------------------------

function SloBody({ data }) {
  return html`
    <div className="grid two">

      ${data.items.map(item => {
        const slo = item.requestSlo;

        return html`
          <div className="card" key=${item.env}>

            <header>
              <h3>${item.label}</h3>

              ${slo
                ? html`
                  <${Badge} kind=${slo.sloMet ? "good" : "bad"}>
                    ${slo.sloMet ? "SLO met" : "SLO missed"}
                  <//>`
                : html`<${Badge} kind="muted">no data<//>`}
            </header>

            ${item.errors.map(message =>
              html`<p className="error" key=${message}>${message}</p>`
            )}

            <dl>
              <dt>Requests (30 days)</dt>
              <dd>${slo ? slo.total : "-"}</dd>

              <dt>Request success</dt>
              <dd>
                ${slo ? percent(slo.availabilitySli) : "-"}
                <span className="muted">
                  target ${data.targets.requestSuccessPercent}%
                </span>
              </dd>

              <dt>Under 500 ms</dt>
              <dd>
                ${slo ? percent(slo.latencySli) : "-"}
                <span className="muted">
                  target ${data.targets.latencyUnder500msPercent}%
                </span>
              </dd>

              <dt>Error budget used</dt>
              <dd>${slo ? percent(slo.budgetUsedPercent) : "-"}</dd>

              <dt>Availability test</dt>
              <dd>
                ${item.availability
                  ? percent(item.availability.percent) +
                    " (" + item.availability.passed +
                    "/" + item.availability.total + ")"
                  : "-"}
                <span className="muted">
                  target ${data.targets.availabilityPercent}%
                </span>
              </dd>
            </dl>

          </div>`;
      })}

    </div>`;
}

// --------------------------------------------------
// Alerts
// --------------------------------------------------

function AlertsBody({ data }) {
  if (data.alerts.length === 0) {
    return html`
      <p className="muted">
        No DeployFlow alerts in the last 7 days.
      </p>`;
  }

  const ordered = data.alerts.slice().sort((a, b) => {
    const rank = alert => alert.condition === "Fired" ? 0 : 1;
    return rank(a) - rank(b);
  });

  const active = ordered.filter(
    alert => alert.condition === "Fired"
  ).length;

  return html`
    <div>

      <p className=${active ? "error" : "muted"}>
        ${active
          ? active + " alert(s) are firing right now. They clear by themselves when the problem is gone."
          : "No alert is firing right now. The resolved alerts below are history."}
      </p>

      <div className="table-wrap">
        <table>

          <thead>
            <tr>
              <th>Rule</th>
              <th>Severity</th>
              <th>Status</th>
              <th>Target</th>
              <th>Fired</th>
              <th>Cleared</th>
            </tr>
          </thead>

          <tbody>
            ${ordered.map((alert, index) => html`
              <tr key=${alert.rule + index}>
                <td>${alert.rule}</td>
                <td>${alert.severity}</td>

                <td>
                  <${Badge}
                    kind=${alert.condition === "Fired"
                      ? "bad"
                      : alert.condition === "Resolved"
                        ? "good"
                        : "muted"}
                  >
                    ${alert.condition === "Fired"
                      ? "Active (firing now)"
                      : alert.condition === "Resolved"
                        ? "Resolved"
                        : "Unknown"}
                  <//>
                </td>

                <td>${alert.target}</td>
                <td>${formatTime(alert.firedAt)}</td>

                <td>
                  ${alert.condition === "Resolved"
                    ? formatTime(alert.changedAt)
                    : "-"}
                </td>
              </tr>
            `)}
          </tbody>

        </table>
      </div>

    </div>`;
}

// --------------------------------------------------
// Admin actions
// --------------------------------------------------

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
    <section className="panel" id="actions">

      <h2>Release Actions</h2>

      ${!isAdmin
        ? html`
          <p className="muted">
            You have read-only access. Only administrators can start actions.
          </p>`
        : null}

      ${isAdmin && !enabled
        ? html`
          <p className="muted">
            Actions are switched off on this dashboard.
          </p>`
        : null}

      <p className="muted">
        Actions start the real Azure DevOps pipelines.
        Production still waits for the approval check in Azure DevOps.
      </p>

      <form
        className="action"
        onSubmit=${event => event.preventDefault()}
      >
        <strong>Request a rollback of production</strong>

        <input
          placeholder="Revision to roll back to (empty = previous revision)"
          value=${target}
          onChange=${event => setTarget(event.target.value)}
          disabled=${!isAdmin || !enabled}
        />

        <input
          placeholder="Reason (3-100 characters, no quotes)"
          value=${reason}
          onChange=${event => setReason(event.target.value)}
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
        >
          Request rollback
        </button>
      </form>

      <form
        className="action"
        onSubmit=${event => event.preventDefault()}
      >
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
        >
          Request deployment
        </button>
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

// --------------------------------------------------
// Main application
// --------------------------------------------------

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
    [
      me,
      environments,
      pipelines,
      deployments,
      security,
      slo,
      alerts
    ].forEach(item => item.reload());
  }

  const deploymentSuccess = deploymentStats
    ? deploymentStats.successRatePercent
    : 0;

  const pipelineSuccess = pipelineStats
    ? pipelineStats.overallSuccessRatePercent
    : 0;

  return html`
    <div className="app-shell">

      <!-- Sidebar -->

      <aside className="sidebar">

        <div className="brand">
          <div className="brand-mark">D</div>

          <div>
            <strong>DeployFlow</strong>
            <small>Release platform</small>
          </div>
        </div>

        <div className="nav-label">Overview</div>

        <a className="nav-item active" href="#overview">
          <span className="nav-icon">▦</span>
          Dashboard
        </a>

        <a className="nav-item" href="#environments">
          <span className="nav-icon">▤</span>
          Environments
        </a>

        <a className="nav-item" href="#analytics">
          <span className="nav-icon">◉</span>
          Analytics
        </a>

        <div className="nav-label">Delivery</div>

        <a className="nav-item" href="#pipelines">
          <span className="nav-icon">⌁</span>
          Pipelines
        </a>

        <a className="nav-item" href="#deployments">
          <span className="nav-icon">⇧</span>
          Deployments
        </a>

        <a className="nav-item" href="#incidents">
          <span className="nav-icon">◈</span>
          Rollbacks & incidents
        </a>

        <div className="nav-label">Monitoring</div>

        <a className="nav-item" href="#security">
          <span className="nav-icon">⬡</span>
          Security
        </a>

        <a className="nav-item" href="#slo">
          <span className="nav-icon">◷</span>
          SLO & reliability
        </a>

        <a className="nav-item" href="#alerts">
          <span className="nav-icon">♧</span>
          Alerts
        </a>

        <div className="nav-label">System</div>

        <a className="nav-item" href="#actions">
          <span className="nav-icon">⚙</span>
          Release actions
        </a>

        <div className="sidebar-health">
          <div className="health-label">
            <span className="live-dot"></span>
            Platform health
          </div>

          <strong>Live monitoring</strong>
          <small>Azure · Azure DevOps</small>
        </div>

      </aside>

      <!-- Main workspace -->

      <div className="workspace">

        <div className="topbar">

          <div className="topbar-title">
            <h1>Dashboard</h1>

            <div className="sub">
              DeployFlow
              <span className="separator">/</span>
              Release operations
              <span className="separator">/</span>

              <span className="live-status">
                <i></i>
                Live data
              </span>
            </div>
          </div>

          <div className="right">

            ${me.data
              ? html`
                <span className="user-name">${me.data.user}</span>

                <${Badge}
                  kind=${me.data.role === "admin" ? "warn" : "muted"}
                >
                  ${me.data.role}
                <//>`
              : null}

            <button className="btn" onClick=${refreshAll}>
              <span className="refresh-icon">↻</span>
              Refresh
            </button>

          </div>
        </div>

        <main id="overview">

          <${ServerBanner} onRecovered=${refreshAll} />

          ${me.error
            ? html`<p className="error">${me.error}</p>`
            : null}

          ${environments.error && environments.data
            ? html`
              <p className="error">
                ${environments.error}
                Showing the last data received at
                ${formatTime(environments.updated)}.
              </p>`
            : null}

          <!-- Environment overview -->

          <div className="section-heading" id="environments">
            <div>
              <h2>Environment Status</h2>
              <p>
                Current health and serving revisions across your environments
              </p>
            </div>

            <span className="section-meta">
              <span className="live-dot"></span>
              Auto-refresh enabled
            </span>
          </div>

          <div className="grid cards">

            ${environments.data
              ? environments.data.environments.map(env =>
                  html`
                    <${EnvironmentCard}
                      env=${env}
                      key=${env.key}
                    />`
                )
              : html`
                <section className="panel">
                  <h2>Environment Status</h2>

                  ${environments.error
                    ? html`<p className="error">${environments.error}</p>`
                    : html`
                      <p className="muted">
                        Loading environment data...
                      </p>`}
                </section>`}

          </div>

          <!-- Performance KPIs -->

          <div className="section-heading compact">
            <div>
              <h2>Release Performance</h2>
              <p>
                Deployment and pipeline metrics for the last 30 days
              </p>
            </div>
          </div>

          <div className="grid kpis">

            <${Kpi}
              label="Deployment success rate"
              value=${deploymentStats
                ? percent(deploymentStats.successRatePercent)
                : "-"}
              hint="Last 30 days"
            />

            <${Kpi}
              label="Deployments"
              value=${deploymentStats
                ? deploymentStats.succeeded + " ok / " +
                  deploymentStats.failed + " failed"
                : "-"}
              hint="Staging and production"
            />

            <${Kpi}
              label="Rollbacks"
              value=${deploymentStats
                ? deploymentStats.rollbacks
                : "-"}
              hint=${deploymentStats
                ? deploymentStats.automaticRollbacks +
                  " automatic · " +
                  deploymentStats.manualRollbacks +
                  " manual"
                : ""}
            />

            <${Kpi}
              label="Pipeline success rate"
              value=${pipelineStats
                ? percent(pipelineStats.overallSuccessRatePercent)
                : "-"}
              hint=${pipelineStats
                ? pipelineStats.overallSucceeded +
                  " succeeded · " +
                  pipelineStats.overallFailed +
                  " failed"
                : ""}
            />

            <${Kpi}
              label="Average CI duration"
              value=${ci
                ? formatDuration(ci.averageDurationSeconds)
                : "-"}
              hint="Build · scan · push"
            />

            <${Kpi}
              label="Average CD duration"
              value=${cd
                ? formatDuration(cd.averageDurationSeconds)
                : "-"}
              hint="Includes approval wait"
            />

          </div>

          <!-- Analytics -->

          <div className="section-heading" id="analytics">
            <div>
              <h2>Analytics Overview</h2>
              <p>
                Visual insights into release performance and reliability
              </p>
            </div>

            <span className="section-meta">
              Last 30 days
            </span>
          </div>

          <div className="analytics-grid">

            <${DonutChart}
              title="Deployment Success"
              subtitle="Staging and production"
              value=${deploymentStats
                ? deploymentStats.succeeded
                : "-"}
              percent=${deploymentSuccess}
              color="#20d989"
            />

            <${DonutChart}
              title="Pipeline Reliability"
              subtitle="CI and CD pipeline runs"
              value=${pipelineStats
                ? pipelineStats.overallSucceeded
                : "-"}
              percent=${pipelineSuccess}
              color="#795cff"
            />

            <${MiniBarChart}
              title="Deployment Outcomes"
              subtitle="Deployment activity"
              items=${[
                {
                  label: "Successful",
                  value: deploymentStats
                    ? deploymentStats.succeeded
                    : 0,
                  color: "#20d989"
                },
                {
                  label: "Failed",
                  value: deploymentStats
                    ? deploymentStats.failed
                    : 0,
                  color: "#ff5268"
                },
                {
                  label: "Rollbacks",
                  value: deploymentStats
                    ? deploymentStats.rollbacks
                    : 0,
                  color: "#ffad42"
                }
              ]}
            />

          </div>

          <!-- Pipeline runs -->

          <div className="section-heading compact" id="pipelines">
            <div>
              <h2>Release Activity</h2>
              <p>
                Recent pipeline executions and deployment history
              </p>
            </div>
          </div>

          <div className="grid dashboard-panels">

            <${Panel}
              title="Pipeline Runs"
              state=${pipelines}
              wide=${true}
              id="pipeline-panel"
            >
              ${pipelines.data
                ? html`
                  <div>

                    ${pipelines.data.missingPipelines.length
                      ? html`
                        <p className="error">
                          Pipelines not found:
                          ${pipelines.data.missingPipelines.join(", ")}
                        </p>`
                      : null}

                    <${PipelinesTable}
                      runs=${pipelines.data.runs}
                    />

                  </div>`
                : null}
            <//>

            <!-- Deployment history -->

            <${Panel}
              title="Deployment History"
              state=${deployments}
              wide=${true}
              id="deployments"
            >
              ${deployments.data
                ? html`
                  <div>

                    ${deployments.data.problems.map(message =>
                      html`
                        <p className="error" key=${message}>
                          ${message}
                        </p>`
                    )}

                    <${DeploymentsTable}
                      events=${deployments.data.events}
                    />

                  </div>`
                : null}
            <//>

            <!-- Incidents -->

            <${Panel}
              title="Deployment Incidents & Failures"
              state=${deployments}
              wide=${true}
              id="incidents"
            >
              ${deployments.data
                ? html`
                  ${deployments.data.failures.length === 0
                    ? html`
                      <p className="muted">
                        No failed deployments or recovered incidents
                        in the last 30 days.
                      </p>`
                    : html`
                      <${DeploymentsTable}
                        events=${deployments.data.failures}
                      />`}
                `
                : null}
            <//>

            <!-- Security -->

            <${Panel}
              title="Security & Scan Results"
              state=${security}
              wide=${true}
              id="security"
            >
              ${security.data
                ? html`
                  <${SecurityBody} data=${security.data} />`
                : null}
            <//>

            <!-- SLO -->

            <${Panel}
              title="Service Reliability & Error Budget"
              state=${slo}
              wide=${true}
              id="slo"
            >
              ${slo.data
                ? html`<${SloBody} data=${slo.data} />`
                : null}
            <//>

            <!-- Alerts -->

            <${Panel}
              title="System Alerts"
              state=${alerts}
              wide=${true}
              id="alerts"
            >
              ${alerts.data
                ? html`<${AlertsBody} data=${alerts.data} />`
                : null}
            <//>

          </div>

          <!-- Admin actions -->

          <div className="grid two actions-layout">
            <${ActionsPanel} me=${me.data} />
          </div>

          <footer>
            Live data from Azure Container Apps, Log Analytics,
            Azure Monitor and Azure DevOps.

            Release actions continue to use the existing
            protected pipeline workflows.
          </footer>

        </main>

      </div>
    </div>`;
}

// --------------------------------------------------
// Render application
// --------------------------------------------------

ReactDOM.createRoot(
  document.getElementById("root")
).render(
  html`<${App} />`
);