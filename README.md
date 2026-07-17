# Comparator

Finds drift across three aspects — ConfigMap, Image and Resource config — and
writes a self-contained HTML report. Three comparisons:

| | Left | Right | Answers |
|---|---|---|---|
| **Kube2Branch** | helm values in Azure DevOps | the live cluster | is what we declared what is actually running? |
| **Folder2Folder** | one env folder, e.g. `sit` | another, e.g. `prd` | what changes when we promote? |
| **Build2Build** | the chart at an old CD run | the chart at a new CD run | what changed between these two releases? |

All three run the same comparators over the same normalised snapshots — the
engine only knows a *left* and a *right* side and the labels it was handed.

## Quick start

Copy or clone the folder, open it in your IDE, and run **`main.py`**. There is
no install step and nothing to build.

```bash
python main.py ui                  # web hub: all three comparisons + config
python main.py                     # Kube2Branch -> reports/comparison-report.html
python main.py --open              # ...and open it
```

If Python complains about a missing package, it tells you exactly what to run:

```bash
python -m pip install -r requirements.txt
```

That is the whole setup. `comparator/` sits next to `main.py`, so Python finds
it on its own — edit anything under it and run `main.py` again.

## Use

```bash
python main.py ui                  # the web hub (below)
python main.py                     # Kube2Branch -> HTML report
python main.py folders --left sit --right prd     # Folder2Folder
python main.py builds --old URL --new URL         # Build2Build
python main.py --open              # open the report when done
python main.py --drift-only        # hide matching rows
python main.py --services aa-flip-owd01
python main.py check               # just test the two connections
python main.py list-comparators    # show the registered checks
```

Bare `python main.py` means `compare`; flags are passed straight through, so
`python main.py --open` needs no subcommand. Handy overrides:

```bash
python main.py --ado-mode local --services aa-amazon-owd01 -n devilsworld
python main.py --branches branch1 branch2 branch3
python main.py folders --left sit --right prd --cluster ske --drift-only
```

## The web hub

```bash
python main.py ui                  # http://127.0.0.1:8765
python main.py ui --port 9000 --no-open
python main.py config              # same hub, landing on the config page
```

A sidebar with four pages; each comparison renders its report inline:

- **Kube2Branch** — namespace + services, then Compare.
- **Folder2Folder** — cluster + two env folders, then Compare. In `local` mode
  the folders are read off disk and offered as dropdowns; over REST they cannot
  be listed, so you type the name.
- **Build2Build** — paste two pipeline run URLs, then Compare. Needs `rest` mode
  and a PAT with Build (Read); the page says so up front if either is missing.
- **Config** — the `config.yaml` editor (below).

It binds to `127.0.0.1` only: it writes to your filesystem and shows the PAT
field, so it is a local tool, not a service. Runs go through the same
`comparator/runner.py` the CLI uses, so a comparison means the same thing
whichever way it was started. Reports are held in memory for the session, not
written to disk — use the CLI (or `-o`) when you want a file.

## Folder2Folder

```bash
python main.py folders --left sit --right prd
```

Both sides are the same chart on the same branch; only the env folder differs,
so the report's columns are labelled `sit` and `prd` rather than
"Azure DevOps"/"Kubernetes". What it catches:

| Case | Reported as |
|---|---|
| Same key, different value (`2G` vs `4G`) | `Mismatch` |
| Key only in prd | `Missing in sit` |
| Service in sit, never promoted to prd | `Missing in prd` |

Images live in one chart-wide `imagesdigest.yaml`, so both sides normally read
the same digest — image rows matching is the expected result there, and the
interesting drift is in properties and resources.

## Build2Build

```bash
python main.py builds \
  --old "https://dev.azure.com/org/proj/_build/results?buildId=8916368" \
  --new "https://dev.azure.com/org/proj/_build/results?buildId=8976368"
```

Paste two **pipeline run** URLs (the ones with `?buildId=` — not a pipeline
definition). Each run is resolved to the commit it was built from
(`sourceVersion`), and the chart is then read **at that commit** on both sides.
So it is not just an image diff: you get the image bump *and* every property
and resource change for each service, for one cluster/env.

| Case | Reported as |
|---|---|
| Image rebuilt | `tag` / `digest` mismatch |
| Property changed between releases | `Mismatch` |
| Property dropped in the new build | `Missing in Build <new>` |
| Service added in the new build | `Missing in Build <old>` |

Requirements and guard rails:

- **`rest` mode only.** Resolving a pipeline URL means calling the Azure DevOps
  API; a local checkout cannot answer it. The UI says so before you paste
  anything, rather than after.
- **The PAT needs `Build (Read)`** on top of `Code (Read)`. A 401 from the
  Build API says exactly that.
- **The run must build the chart repo.** If a run's `repository` is not the
  configured one, its commit means nothing here — that is refused rather than
  read as an empty chart.
- Two runs on the same commit, or a URL with no `buildId`, are refused with the
  reason.
- The configured `branches:` are **not** validated for this comparison — a
  commit already says which tree to read, so a stale branch entry cannot fail
  the run.

If your services are split across branches, note that a CD run builds from one
branch, so a Build2Build covers that branch's services.

## Layout

```
main.py                         <- run this
config/config.yaml              all tunables; ${ENV:default} interpolation
comparator/
  connections/                  transport only -- auth + raw bytes
    azure_devops.py             rest (Repos API) | local (checkout)
    ado_builds.py               pipeline run URL -> the commit it built
    kubernetes.py               kubeconfig | in_cluster
  sources/                      backend -> ServiceSnapshot
    ado.py                      images file + service file + common file
    k8s.py                      Deployment + its ConfigMap
  comparison/
    registry.py                 @register("name") plug-in point
    comparators.py              configmap / image / resources
    normalizers.py              2G vs 2Gi vs 2048Mi -> one number
    engine.py                   pairs a left + right source; knows neither
  report/
    templates/report.html       ALL report styling lives here
  webui/                        the local hub
    server.py                   stdlib http.server; 127.0.0.1 only
    schema.py                   which settings appear in Config -- add here
    yaml_edit.py                comment-preserving edits (no round-trip)
    templates/                  base.html + one per page
  runner.py                     the three comparisons; CLI and web both call this
  models.py                     ServiceSnapshot, Difference, ...
  cli.py                        argument parsing; main.py delegates here
requirements.txt                the four dependencies
tests/
```

The layering is the point: **connections** know transport but not meaning,
**sources** know meaning but not comparison, **comparators** see only
snapshots — and only ever a *left* and a *right*, never "ADO" or "k8s". That
last part is why neither new comparison needed its own comparator:
Folder2Folder is two `AdoSource`s with different `env`s, and Build2Build is two
with different `ref`s (each build's commit) -- both handed to the same engine.

A new backend or a new check touches exactly one layer.

There is deliberately no `pyproject.toml` and no packaging step: `comparator/`
sits beside `main.py`, which is all Python needs to import it.

## Configuration

### Editing it in a browser

```bash
python main.py config          # the hub, landing on the config page
python main.py ui --port 9000
```

A local editor for every setting, grouped by section, that loads with the
values currently in the file and writes them back on Save. It binds to
`127.0.0.1` only — it writes to your disk and shows the PAT field, so it is an
editor, not a service.

Two things it deliberately does **not** do:

- **It never round-trips the YAML.** PyYAML drops comments, and loading
  resolves `${ENV:default}` placeholders — so a load/dump would strip the
  documentation out of this file and freeze whatever your environment held at
  the time. The editor rewrites only the value on the lines you changed; every
  other byte, comments included, is untouched.
- **It shows values exactly as the file has them.** A field reading
  `${K8S_NAMESPACE:devilsworld}` displays that placeholder, not `devilsworld`,
  so saving cannot silently bake it into a literal. What it currently resolves
  to is shown underneath as a read-only hint.

Every save backs the file up to `config.yaml.bak` first, and the result is
parsed before it is written — an edit that would produce invalid YAML is
rejected rather than saved.

### Editing it by hand

Everything lives in `config/config.yaml`, and any value can come from the
environment instead, so no secret needs to be committed:

```bash
export ADO_MODE=rest
export ADO_ORG=my-org ADO_PROJECT=my-project ADO_REPO=DevilsWorld
export ADO_PAT=xxxxxxxx           # scope: Code (Read)
export ADO_BRANCHES="branch1,branch2,branch3"
export K8S_CONTEXT=minikube
```

`ADO_MODE=local` reads the same files from `ADO_ROOT` — no PAT, no network —
which is what the tests and offline runs use.

## Which services get compared

Nothing to list. Leave `target.services` empty and the run covers **every
service either side knows about** — the union of what the branches' images
files declare and what is deployed in the namespace:

```yaml
target:
  services: []          # discover
  exclude: []           # globs to drop, e.g. redis-*
```

The union is the point. A hand-maintained list can only ever contain services
you remembered, so it silently hides the two most interesting cases:

| Case | Reported as |
|---|---|
| Declared in the chart, not deployed | `Missing in Kubernetes` |
| Deployed, declared nowhere | `Missing in Azure DevOps` |

Set `services` explicitly (or pass `--services`) only to narrow a run:

```bash
python main.py --services aa-flip-owd01
```

Note `target.service_branches` is **not** a service list — it pins a service to
a *branch*, overriding branch discovery, and is expected to stay empty.

## Services split across branches

A chart's services often live on different branches (branch1 owns 50, branch2
50, branch3 40). Each service's values live on exactly **one** branch, so every
service is resolved to its branch before being read:

```yaml
connections:
  azure_devops:
    branches: [branch1, branch2, branch3]   # searched in order
```

Resolution order:

1. an explicit pin in `target.service_branches` (for the odd service discovery
   gets wrong — not for the other 139),
2. the branch whose **images file** declares the service,
3. probing each branch for the values file.

The cost matters at 140 services: the images file is read **once per branch**,
not once per service, so a run is ~1 values read per service (≈143 requests)
rather than one per branch per service (≈420).

The values file is the authority — an images-file hint is always confirmed
against it, and anything ambiguous is reported rather than quietly resolved:

| Situation | What the report says |
|---|---|
| Values file on 2+ branches | `values file exists on multiple branches (…); using X` |
| Images file claims it, no values file there | `…declares this service but no values file is there` |
| No images file declares it | `no images file declares this service; resolved to X by its values file` |
| On no branch at all | `no values file on any configured branch (…)` |

Each service's resolved branch is shown as a chip in the report and in the CLI
output. `branches` also accepts a comma-separated string (handy for
`ADO_BRANCHES`), and `branch:` remains the single-branch spelling.

To model this offline, point each branch at its own checkout:

```yaml
    branch_roots:
      branch1: d:/checkouts/branch1
      branch2: d:/checkouts/branch2
```

## Adding a utility feature

Comparators are registered by name, so the engine never changes:

```python
# comparison/comparators.py
@register("ingress")
def compare_ingress(ado, k8s, cfg) -> AspectResult:
    ...
```

Then switch it on:

```yaml
comparison:
  enabled:
    ingress: true
```

New backend? Implement `RepoConnection` (or a `SnapshotSource`) and register it
the same way — nothing downstream cares.

## Notes on the source data

The helm values files are hand-maintained and **not strictly valid YAML**: they
mix tabs and spaces, write `replicaCount:1` with no space, and hold
`serviceProperties` as a free-form block that was never marked `|-`. Rather than
fail, `utils/yaml_utils.py`:

1. lifts the properties blocks out by indentation before YAML sees them,
2. repairs the remainder (tabs at the **8-column** stop — this is load-bearing;
   expanding at 4 lands nested keys shallower than their parent and YAML
   rejects the block),
3. reports every repair as an issue on the report, so nothing is fixed silently.

The cleaner long-term fix is to correct the source files; until then the report
tells you which ones needed repair.

## The report

`report/templates/report.html` is the whole presentation layer: an admin-dashboard
theme (dark slate sidebar, light canvas, white cards, gradient KPI strips) built
from CSS custom properties in one `<style>` block. Restyling is a token edit — no
Python changes.

It is a single self-contained file — no CDN, no fonts, no JS libraries — so it can
be emailed or published as a CI artifact and still render. Icons are inline SVG.

- **Sidebar** jumps to each service and shows its status dot + drift count.
- **KPI row** leads with services / in-sync / with-drift / drifted-keys.
- **Show drift only** hides matching rows client-side (CSS class on `<body>`);
  `--drift-only` does the same at generation time if you'd rather not ship them.
- Status is never colour-alone — every pill carries its label, so the report
  survives colourblindness, greyscale printing and `forced-colors`.
- Dark mode is a deliberate second set of tokens via `prefers-color-scheme`.
- Print stylesheet drops the sidebar and avoids breaking cards across pages.

## Tests

```bash
python -m pip install pytest
python -m pytest tests/ -q
```
