"use strict";

// Cost and resources panels (Milestone 9). They reuse helpers defined in app.js:
// useApi, Panel, Kpi, Badge, formatTime and percent.
(function () {
  const html = htm.bind(React.createElement);

  function money(value, currency) {
    if (value === null || value === undefined) return "-";
    return (currency || "USD") + " " + Number(value).toFixed(2);
  }

  function usd(value) {
    return "$" + Number(value).toFixed(2);
  }

  function CostBody({ data }) {
    const actual = data.actual;
    const estimate = data.estimate;
    const currency = data.currency || "USD";
    const isActual = data.source === "actual";
    const budget = (data.budgets || [])[0];

    const estimateRange = estimate
      ? usd(estimate.lowUsd) + " to " + usd(estimate.highUsd)
      : "-";

    const days = actual && actual.daily ? actual.daily : [];
    const maxDay = Math.max(0.01, ...days.map((day) => day.cost));

    return html`
      <div>
        <div className=${"notice" + (isActual ? " good" : "")}>
          ${isActual
            ? "Actual cost from Azure Cost Management. It is delayed by several hours and can still change while Azure processes usage. It is not real time."
            : "ESTIMATE, not a billed amount. Azure Cost Management data is not available here" +
              (data.actualError ? " (" + data.actualError + ")" : "") +
              ". The numbers below come from the resources that exist and approximate public prices."}
        </div>

        <div className="grid kpis">
          <${Kpi}
            label=${isActual ? "Month to date (actual)" : "Month estimate (range)"}
            value=${isActual ? money(actual.monthToDate, currency) : estimateRange}
            hint=${isActual ? "delayed by hours" : "assumed prices, check Azure pricing"}
          />

          <${Kpi}
            label="Estimated monthly range"
            value=${estimateRange}
            hint="from the resources that exist"
          />

          <${Kpi}
            label="Budget used"
            value=${budget && budget.percentUsed !== null ? percent(budget.percentUsed) : "-"}
            hint=${budget ? money(budget.currentSpend, currency) + " of " + money(budget.amount, currency) : (data.budgetError ? "budget not readable" : "no budget found")}
          />
        </div>

        ${data.budgetError
          ? html`<p className="error">Budgets: ${data.budgetError}</p>`
          : null}

        ${isActual
          ? html`
            <h3 className="muted">Cost by resource group (month to date)</h3>
            <div className="table-wrap">
              <table>
                <thead><tr><th>Resource group</th><th>Cost</th></tr></thead>
                <tbody>
                  ${actual.byResourceGroup.map((group) => html`
                    <tr key=${group.name}>
                      <td>${group.name}</td>
                      <td>${money(group.cost, currency)}</td>
                    </tr>`)}
                </tbody>
              </table>
            </div>

            <h3 className="muted">Daily cost (last 14 days)</h3>
            ${actual.dailyError
              ? html`<p className="error">${actual.dailyError}</p>`
              : null}
            <div className="table-wrap">
              <table>
                <thead><tr><th>Date</th><th>Cost</th><th></th></tr></thead>
                <tbody>
                  ${days.map((day) => html`
                    <tr key=${day.date}>
                      <td>${day.date}</td>
                      <td>${money(day.cost, currency)}</td>
                      <td style=${{ width: "50%" }}>
                        <div className="traffic">
                          <span style=${{ width: Math.round(100 * day.cost / maxDay) + "%" }}></span>
                        </div>
                      </td>
                    </tr>`)}
                </tbody>
              </table>
            </div>`
          : null}

        <h3 className="muted">What the estimate is based on</h3>
        ${data.estimateError
          ? html`<p className="error">${data.estimateError}</p>`
          : null}
        ${estimate
          ? html`
            <div className="table-wrap">
              <table>
                <thead>
                  <tr><th>Resource</th><th>Count</th><th>Low (USD / month)</th><th>High (USD / month)</th><th>Assumption</th></tr>
                </thead>
                <tbody>
                  ${estimate.lines.map((line) => html`
                    <tr key=${line.label}>
                      <td>${line.label}</td>
                      <td>${line.count}</td>
                      <td>${usd(line.lowUsd)}</td>
                      <td>${usd(line.highUsd)}</td>
                      <td className="muted">${line.note}</td>
                    </tr>`)}
                </tbody>
              </table>
            </div>
            <p className="muted">
              Resource types with no charge or no estimate here: ${estimate.freeTypes.length ? estimate.freeTypes.join(", ") : "none"}.
              Ranges are approximate. Real cost depends on usage, region and offer.
            </p>`
          : null}

        <p className="muted">Generated ${formatTime(data.generatedAt)}. Refreshes about every 10 minutes.</p>
      </div>`;
  }

  function ResourcesBody({ data }) {
    const idle = data.apps.filter((app) => app.flags.length > 0).length;

    return html`
      <div>
        <p className="muted">
          ${data.apps.length} container app(s), ${data.apps.filter((app) => app.status === "running now").length} running now,
          ${idle} with a note. "Scaled to zero" apps cost almost nothing until they get a request.
          Requests are counted over the last ${data.requestWindowDays} days, health checks excluded.
        </p>

        ${data.requestError
          ? html`<p className="error">Request counts are unavailable (${data.requestError}), so idle detection is switched off.</p>`
          : null}

        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>App</th>
                <th>Resource group</th>
                <th>Status</th>
                <th>Active revisions</th>
                <th>Requests (${data.requestWindowDays}d)</th>
                <th>Last request</th>
                <th>Notes</th>
              </tr>
            </thead>
            <tbody>
              ${data.apps.map((app) => html`
                <tr key=${app.name}>
                  <td>${app.name}</td>
                  <td>${app.resourceGroup}</td>
                  <td>
                    <${Badge} kind=${app.status === "running now" ? "good" : "muted"}>${app.status}<//>
                  </td>
                  <td>${app.activeRevisions}</td>
                  <td>${app.requests}</td>
                  <td>${formatTime(app.lastRequestAt)}</td>
                  <td>
                    ${app.flags.length === 0
                      ? html`<span className="muted">-</span>`
                      : app.flags.map((flag) => html`<div className="muted" key=${flag}>${flag}</div>`)}
                  </td>
                </tr>`)}
            </tbody>
          </table>
        </div>

        <h3 className="muted">Resource groups</h3>
        <div className="table-wrap">
          <table>
            <thead><tr><th>Resource group</th><th>Protection</th><th>Managed by</th></tr></thead>
            <tbody>
              ${data.resourceGroups.map((group) => html`
                <tr key=${group.name}>
                  <td>${group.name}</td>
                  <td>
                    <${Badge} kind=${group.protected ? "warn" : "muted"}>
                      ${group.protected ? "protected (do not delete by accident)" : "removable"}
                    <//>
                  </td>
                  <td>${group.managedBy || "-"}</td>
                </tr>`)}
            </tbody>
          </table>
        </div>
      </div>`;
  }

  function CostApp() {
    const cost = useApi("/api/cost", 600000);
    const resources = useApi("/api/resources", 300000);

    return html`
      <div className="grid">
        <${Panel} title="Cost, estimates and budget" state=${cost} wide=${true}>
          ${cost.data ? html`<${CostBody} data=${cost.data} />` : null}
        <//>

        <${Panel} title="Resources: what is running and what looks idle" state=${resources} wide=${true}>
          ${resources.data ? html`<${ResourcesBody} data=${resources.data} />` : null}
        <//>
      </div>`;
  }

  ReactDOM.createRoot(document.getElementById("cost-root")).render(
    html`<${CostApp} />`
  );
})();