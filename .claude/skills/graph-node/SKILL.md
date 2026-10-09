---
name: graph-node
description: How to produce, declare, validate and read graph/1 envelopes with GraphNode, the base graph shape shared by every graph module (emitters such as Graph.Emitter.FileSystem, Graph.Emitter.Network, Graph.Emitter.Terraform, Graph.Emitter.AzureDevOps; consumers such as GraphRenderer). Use any time this repo writes or reads a graph.json envelope or an ontology.yaml, builds nodes, edges or node ids, or reports GraphNode problem codes.
version: 0.2.1
---

# GraphNode for emitters and consumers

GraphNode owns the shape: one Node, one Edge, one Envelope (`schema: graph/1`), the schema your `ontology.yaml` must satisfy, the registry of node id prefixes, and a validator in PowerShell and Go. Your repo produces or reads that shape; it never redefines it. If the shape does not fit what you need, propose a change to GraphNode; do not work around it locally.

`reference/` beside this file holds a complete example to open: `envelope.example.json` (a valid envelope) and `ontology.example.yaml` (the ontology it names; in your repo the file is `ontology.yaml`, which is the name the example envelope uses).

## When to use

Any time a repo produces or reads graph/1 envelopes: building nodes and edges from a source, choosing node ids, writing a layer, writing or changing `ontology.yaml`, validating output in tests or CI, or loading layers to draw, diff or merge them.

## Depend on GraphNode

PowerShell (7.4+). Until GraphNode is on a feed, import it from the sibling checkout (the module inside is still named GraphNode):

```powershell
Import-Module C:\__Code\Graph.Node\src\GraphNode\GraphNode.psd1
```

Once it is on a feed, declare it in your psd1 instead: `RequiredModules = @(@{ ModuleName = 'GraphNode'; ModuleVersion = '0.2.0' })`. Do not copy GraphNode's files into your module.

Go (1.24+). Import the package and pin it to a tag in `go.mod`, never `latest` or a branch:

```
go get github.com/JerryBalmer1/GraphNode/graph@v0.2.0
```

The package embeds the schemas, so `graph.Validate` needs no files on disk.

## Produce an envelope

PowerShell:

```powershell
Import-Module C:\__Code\Graph.Node\src\GraphNode\GraphNode.psd1
$layer = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
$vnet  = New-GraphNode -Id 'vnet:a' -Kind VNet -Name vnet-a -Properties @{ cidr = '10.0.0.0/16' } -Source @{ tool = 'az'; command = 'az network vnet show -n vnet-a' }
$snet  = New-GraphNode -Id 'snet:a' -Kind Subnet -Name snet-a -Properties @{ cidr = '10.0.1.0/24' }
$edge  = New-GraphEdge -From $vnet -To $snet -Kind contains
$env   = New-GraphEnvelope -Module Example -Version 0.1.0 -Layer $layer -Ontology 'ontology.yaml' -Nodes $vnet, $snet -Edges $edge
Export-Graph $env -Path ".\layers\$($layer -replace ':', '-')\graph.json"
```

- `New-GraphNode -Id -Kind` are required; `-Name`, `-Properties`, `-Source`, `-Findings`, `-Layer` (sets `stamp.layer`) are optional and omitted from the JSON when not given. `New-GraphNode`, `New-GraphEdge` and `New-GraphEnvelope` write any `[datetime]` or `[DateTimeOffset]` given as `-Layer` or as a top-level `-Properties` value as a UTC stamp `yyyy-MM-ddTHH:mm:ssZ` (whole seconds), so `-Layer (Get-Date)` is safe. Strings are written as given.
- `New-GraphEdge -From -To -Kind` takes node objects or id strings and sets the edge id for you, escaping as below.
- `New-GraphEnvelope -Module -Layer` are required; it sets `schema: graph/1` and fills `counts` (`nodes`, `edges`, `byKind`). `-Version`, `-Root`, `-Ontology`, `-Findings` (envelope-level findings) are optional.
- `Export-Graph` runs `Test-Graph` first and throws on any error (warnings do not block) unless `-Force`; it writes UTF-8 without BOM, LF line endings, and creates the directory.

Go: `env := graph.NewEnvelope(module, version, layer)`, append `graph.Node{ID: ..., Kind: ...}` and `graph.NewEdge(from, to, kind)`, then `env.Recount()` and `graph.Save(path, env)`. `NewEnvelope` keeps the lists non-nil so they serialise as `[]`.

Rules:
- Edge id is `from|to|kind`, with every `%` and `|` inside `from` and `to` percent-encoded as `%25` and `%7C`: `vnet:a|snet:a|contains`, and for a file named `a|b.txt`, `fs:a%7Cb.txt|fs:.|contains`. The edge's `from` and `to`, and the node ids, keep the raw characters. Ids without `%` or `|` are unchanged. Build edge ids with `New-GraphEdge` or `graph.NewEdge` / `graph.EdgeID`, never by hand; split one with `graph.ParseEdgeID`. A well-formed id naming the wrong endpoints is `edge-id`; one that does not split into three parts or holds any other `%` sequence is `edgeid`.
- Node id stability across layers is your job. The same real thing must get the same id in every layer, or a diff sees a delete and an add. Write the rule for each Kind as `idRule` in your `ontology.yaml` (`"vnet:<name>"`) and follow it.
- Kind names match `^[A-Za-z][A-Za-z0-9_.-]*$`. `New-GraphNode` and `New-GraphEdge` reject anything else.
- One envelope per layer: each run of your emitter writes one complete envelope of what it saw, never a patch. `layer` is required and must sort in time order as a string. Stamps are UTC ending `Z`: `layer`, `stamp.layer`, `stamp.firstSeen`, `stamp.lastSeen` and ActionRun `startedAt` and `finishedAt` must match `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$` (`2026-10-08T00:00:00Z`); a `+hh:mm` offset or no zone is a `stamp` problem. Keep one width across layers (whole seconds, as the builders write) so string order is time order. Put the same value in `stamp.layer` (`-Layer`) if you stamp nodes.
- Required: Node `id`, `kind`; Edge `id`, `kind`, `from`, `to`; Envelope `schema`, `module`, `layer`, `nodes`, `edges`. Everything else is optional and tolerated when absent, so leave out what you do not know rather than writing empty values.
- `source` is a list of `{tool, command, path, file, line}`, all optional. `findings` is a list of `{kind, severity, message, target}`; `kind` and `message` are required by the Go types.

## Node id prefixes

Some id prefixes are registered to a module; GraphNode's `schemas/ids.md` is the table. `Get-GraphIdPrefix` (PowerShell), `graph.IDPrefixes()` (Go) and `graphnode prefixes` return it as `Prefix`, `Owner`, `Shape`:

| Prefix | Owner | Shape |
|---|---|---|
| `fs:` | Graph.Emitter.FileSystem | `fs:` + path relative to the root, forward slashes; the root is `fs:.`; no trailing slash; case preserved |
| `ui:` | Graph.Portal | reserved |
| `run:`, `finding:`, `decision:`, `notrun:`, `touched:` | Graph.RunReport | the run report's id rules |
| `alert:` | Claude.Agent.Alerts | `alert:<rule>:<seq>` or `alert:<rule>:line-<n>`; rule `^[a-z][a-z0-9-]*$` |
| `ledger:` | Claude.Agent.Alerts | `ledger:<seq>` or `ledger:line-<n>` |

- If your module owns a prefix, every id with it must have the registered shape. Check with `Test-GraphId -Prefix fs -Id 'fs:src/main.go'` (one `[bool]` per id, pipeline input allowed; `-Verbose` says why one fails), `graph.ValidID("fs", id)` or `graphnode check-id fs <id>`.
- To edge to a node another module owns (a Terraform resource to the `.tf` file it came from), use that module's prefix and shape, `fs:modules/net/main.tf`, so the edge meets the node when a merge brings the layers together. In your own envelope that endpoint is missing: both validators report the `dangling-edge` as a warning, not an error, when the missing id carries a registered prefix whose owner is not your envelope's `module`. A missing id with your own prefix, or no registered prefix, is an error.
- To register a prefix, propose it to GraphNode; never issue ids with a prefix another module owns for your own nodes.

## Declare an ontology

Your repo ships one `ontology.yaml` that declares every Kind, edge Kind and finding Kind you emit. It is validated against GraphNode's `ontology.schema.json`; unknown keys fail.

```yaml
module: Example
version: 0.2.1
kinds:
  VNet:
    description: A virtual network.
    idRule: "vnet:<name>"
    properties: [cidr]
    display: { color: "#4a90e2", shape: square, size: 3 }
  Subnet:
    idRule: "snet:<name>"
    properties:
      - { name: cidr, type: string, required: true }
    display: { color: "#2ec4b6", shape: hexagon, icon: network }
    actions:
      - name: attach
        description: Attach a VM to this subnet.
        inputs:
          - { name: vm, type: VM, required: true }
          - { name: primary, type: boolean }
        returns: { type: string, description: id of the new NIC }
        trigger: manual
        permissions: [network.write]
edgeKinds:
  contains: { from: [VNet], to: [Subnet], display: { color: "#4a90e2", style: solid } }
findingKinds:
  unused-subnet: { severity: info }
```

- `kinds` is required. Each Kind may have `description`, `idRule`, `properties` (names, or `{name, type, required, description}` with `type` one of string, integer, number, boolean, object, array), `display` and `actions`.
- Kind `display` is `{color, shape, icon, size, label, collapsed}`: `color` is `#rrggbb`; `shape` is `circle`, `square`, `diamond` or `hexagon`; `size` is an integer of 1 or more; `icon` is a name; `label` is a template where `{name}` and `{properties.x}` substitute. The 0.1.0 shape names `round-rectangle`, `rectangle`, `ellipse` and `octagon` are accepted with a `display` warning until 0.3.0; move to the four.
- Edge Kind `display` is `{color, style}`: `style` is `solid`, `dashed` or `dotted`. No `shape`, `icon` or `size` on edge Kinds.
- Display lives here, per Kind and edge Kind, and never on a node or edge: the node and edge schemas reject a `display` key (`schema`). A renderer resolves it by `node.kind` / `edge.kind` from the ontology, so changing a colour is an ontology change, not a re-emit.
- `actions` are `{name, description, inputs, returns, trigger, permissions}`. `inputs` is a list of `{name, type, required, description}`; `returns` is `{type, description}`. A `type` is a JSON type (string, integer, number, boolean, object, array) or a Kind name, meaning the value is that node's id. The 0.1.0 `inputs: { name: type }` map is accepted with an `action` warning until 0.3.0. `trigger` is `manual`, `on-change`, `schedule:<cron>` or `event:<name>`. Actions are declared only; running one is the ledger's job and produces an ActionRun node.
- `edgeKinds` give `from` and `to` as lists of Kind names, plus optional `description` and `display`.
- `findingKinds` give an optional `description` and `severity` (`info`, `warning`, `error`).
- If you emit a base Kind (ActionRun), declare it under `kinds` too so it has a display.
- `envelope.ontology` names the file (`"ontology": "ontology.yaml"`), as a path or URL. A relative path is relative to the directory of the envelope file, so `ontology.yaml` means the file beside `graph.json`, and `../ontology.yaml` one level up. Set it with `New-GraphEnvelope -Ontology`. `schema` stays `graph/1` regardless of your ontology's version.

## Validate

Every problem has a severity, `error` or `warning`. An envelope or ontology is valid when it has no errors; warnings are reported and never block.

PowerShell:
- `Test-Graph $env` or `Test-Graph -Path .\graph.json` runs the pure-PowerShell checks and returns `Valid`, `Problems` (each `Code`, `Path`, `Message`, `Severity`) and `Strict`. No binary needed.
- `Test-Graph ... -Strict` also runs the `graphnode` binary for full JSON Schema validation, including the base Kind schemas. It needs the binary built in the GraphNode checkout (`src\GraphNode\bin\win-x64\graphnode.exe` or `bin/linux-x64/graphnode`); if it is not built, `-Strict` throws `Test-Graph -Strict needs the graphnode binary: build the graphnode binary; see README` (GraphNode's README); on a platform with no binary (macOS today) it throws `no graphnode binary for this platform (win-x64, linux-x64)`. CI should run `-Strict` (or `graphnode validate`).
- `Test-Graph ... -Ontology .\ontology.yaml` also validates that ontology (display blocks, actions) and checks every ActionRun's `inputs` and `result` against the action its `action` names. Ontology problems have paths starting `ontology:`. It reads YAML through the binary, so it implies `-Strict` and needs the binary. Run it on request (in CI, say); it is not part of the default check.

Go and CI:
- `graph.Validate(env)` or `graph.ValidateBytes(data)` returns `[]graph.Problem` (`Code`, `Path`, `Message`, `Severity`), nil when there is nothing to report; `graph.HasErrors(ps)` is the validity test. `graph.ValidateOntology(doc)` checks a decoded ontology. `graph.ValidateWithOntology(data, doc)` does both plus `graph.CheckActionRuns(env, doc)`.
- `graphnode validate <graph.json> [--ontology <ontology.yaml>]` and `graphnode validate-ontology <ontology.yaml>` print a JSON array of `{code, path, message, severity}` (`[]` when clean) and exit 0 when there is no error (warnings only, or nothing), 1 on any error, 2 on a usage or read error. `graphnode prefixes` prints the id prefix registry; `graphnode check-id <prefix> <id>` exits 1 and prints why when the id does not fit. `graphnode schema` lists the schema names; `graphnode schema <name>` prints one; `graphnode version` prints the version.

Problem codes (the same in both validators; a code one reports and the other does not is a GraphNode bug, report it):

| Code | Means |
|---|---|
| `schema` | A required field is missing or wrong (`schema` not `graph/1`, no `module`, `layer`, `nodes` or `edges`, a node or edge without its required fields, a node or edge Kind name that does not match the pattern, a `display` key on a node or edge), or, with `-Strict` / Go, any other JSON Schema violation; Go checks the full base Kind schemas, so it can find more `schema` problems than pure `Test-Graph`. Also the code for a file that is not JSON. |
| `duplicate-node` | Two nodes in the envelope have the same `id`. |
| `duplicate-edge` | Two edges in the envelope have the same `id`. |
| `dangling-edge` | An edge's `from` or `to` is not the id of a node in the same envelope. A warning when the missing id carries another module's registered prefix; otherwise an error. |
| `edge-id` | An edge's `id` is well formed but is not `from|to|kind` for its own `from`, `to` and `kind`. |
| `edgeid` | An edge's `id` is malformed: not three `|`-separated parts (an unescaped `|` in an id), or a `%` that does not start `%25` or `%7C`. |
| `counts` | `counts.nodes` or `counts.edges` disagrees with the lists. |
| `kind` | A base Kind node is missing what its schema requires (ActionRun `action`, `startedAt`; Category `label`). |
| `stamp` | `layer`, `stamp.layer`, `stamp.firstSeen`, `stamp.lastSeen`, or ActionRun `startedAt` or `finishedAt` is not a UTC ISO-8601 stamp ending `Z`. |
| `display` | In an ontology: a display block that breaks its rules (colour not `#rrggbb`, unknown shape or style, size below 1, an unknown key); a warning for a 0.1.0 shape name. |
| `action` | In an ontology: an action declaration that breaks its rules, or a warning for a 0.1.0 `inputs` map. With `-Ontology` / `--ontology`: an ActionRun missing a required input, with an undeclared or wrongly typed input, or with a `result` of the wrong type; a warning for an ActionRun whose action the ontology does not declare. |

What the validators do not check yet: that a node's or edge's Kind is declared in your `ontology.yaml`, and that an edge's endpoints match its edge Kind's `from` / `to`. Those rules are yours to keep.

## Read an envelope

- `Import-Graph .\graph.json` returns the envelope with `nodes`, `edges` and `findings` always present (empty arrays when missing). Validate it with `Test-Graph` before trusting it.
- `Import-Graph` (PowerShell's JSON reader) turns ISO-8601 strings such as `layer`, `startedAt` and `finishedAt` into `[datetime]`. A valid `Z` stamp exports back unchanged and `Test-Graph` accepts it; an offset stamp (invalid anyway) would come back rewritten in the local time zone. Compare layers as the strings in the file.
- `Get-GraphSchema envelope` (or `node`, `edge`, `ontology`, `action-run`, `category`) returns a schema as a hashtable; `-Raw` returns the JSON text; `-List` lists all six.
- Go: `graph.Load(path)` or `graph.Decode(r)` returns `*graph.Envelope`, filling empty lists; `env.NodeIndex()` maps id to index. `graph.SchemaNames()` and `graph.SchemaBytes(name)` expose the embedded schemas. `graph.ParseEdgeID(id)` returns the decoded from, to and kind; `graph.PrefixOf(id)` returns the registered prefix an id carries.
- Tolerate every optional field being absent. Resolve display, edge rules and actions from the ontology the envelope names, not from the nodes. An edge whose far end has another module's prefix points into that module's layer.

## Base Kinds you may emit

| Kind | When | Properties | Edges |
|---|---|---|---|
| `ActionRun` | One execution of an action declared in an ontology, recorded by whatever ran it. Emit it only when your repo actually runs actions. | Required `action` (`<Kind>.<action name>`, e.g. `Subnet.attach`), `startedAt`; optional `finishedAt`, `status` (`running`, `succeeded`, `failed`, `cancelled`), `actor`, `inputs` (name to value, matching the action's declared `inputs`), `result` (matching its `returns.type`). `startedAt` and `finishedAt` are UTC stamps ending `Z`. | `performed-on` to each target node; `produced` to each node it created or changed. |
| `Category` | Never from an emitter. Only the taxonomy module writes it. | Required `label`; optional `description`. | Kinds join it by `is-a` edges. |

Any other Kind is yours and is declared in your `ontology.yaml`. Never add your own Kinds to GraphNode.

## What not to do

- No per-emitter node types. One Node shape with a `kind` string; what a Kind carries goes in `properties` and is declared in `ontology.yaml`.
- No display on nodes or edges (`color`, `shape`, `icon`, ...): the schema rejects it. Display lives in `ontology.yaml`.
- No edge to a missing node except one into another module's registered prefix; that one is a warning until a merge resolves it. Inside your own ids, a missing endpoint is an error.
- No hand-built edge ids. Use `New-GraphEdge`, `graph.NewEdge` or `graph.EdgeID`.
- No Kind, edge Kind or finding Kind that is not declared in your `ontology.yaml`.
- No `Category` nodes from an emitter, and no edits to another module's layers.

## Changes

- 0.1.0: initial; stamps (`layer`, `stamp.*`, ActionRun `startedAt`, `finishedAt`) must be UTC ending `Z`, builders convert `[datetime]`, new code `stamp`; `display` on a node or edge is rejected (`schema`); pure `Test-Graph` checks the edge Kind pattern; a relative `envelope.ontology` path is relative to the envelope file's directory; `-Strict` errors for an unbuilt binary or an unsupported platform.
- 0.2.0: problems carry `severity` (`error`, `warning`) and only errors fail; Kind `display` checked (`#rrggbb` colour, shape circle|square|diamond|hexagon, integer `size`), edge Kind `display` is `{color, style}`, new code `display`; id prefix registry (`schemas/ids.md`), `Get-GraphIdPrefix`, `Test-GraphId`, `graphnode prefixes` and `check-id`, `graph.IDPrefixes`, `ValidID`, `PrefixOf`, and a dangling edge to another module's prefix is a warning; `%` and `|` in edge id parts are percent-encoded, new code `edgeid`, `graph.ParseEdgeID`; action `inputs` as `[{name, type, required}]` and `returns: {type}`, ActionRun `result`, `Test-Graph -Ontology` and `graphnode validate --ontology` check ActionRuns, new code `action`, `graph.ValidateWithOntology`, `CheckActionRuns`, `HasErrors`. 0.1.0 shapes and `inputs` maps are warnings until 0.3.0.
- 0.2.1: `ui:` is registered to Graph.Portal, not GraphRenderer; `alert:` and `ledger:` are registered to Claude.Agent.Alerts, with their shapes checked by `Test-GraphId`, `graph.ValidID` and `graphnode check-id` (`schemas/ids.md`, `Get-GraphIdPrefix`, `graph.IDPrefixes`, `graphnode prefixes`).
