"""
ZuluGraphEngine — Graphify core logic, self-contained, zero external deps beyond networkx.
Pipeline (mirrors safishamsi/graphify):
  1. AST extract  → nodes + edges per .py file (tree-sitter replaced by Python's own ast module)
  2. Build        → NetworkX DiGraph
  3. Cluster      → Louvain community detection
  4. Analyze      → god nodes, surprise cross-community edges
  5. Report       → markdown GRAPH_REPORT.md + graph.json

Usage:
  from zulu_graph import ZuluGraphEngine
  engine = ZuluGraphEngine('/path/to/your/project')
  report = engine.run()          # returns markdown string
  engine.save('graphify-out/')   # saves graph.json + GRAPH_REPORT.md
"""
from __future__ import annotations
import ast as _ast
import hashlib
import json
import re
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path
from typing import Any

import networkx as nx

# ── 1. AST EXTRACTION (Python files only; mirrors graphify's tree-sitter pass) ──

def _safe_name(node) -> str | None:
    if isinstance(node, _ast.Name):
        return node.id
    if isinstance(node, _ast.Attribute):
        return node.attr
    return None

def _make_id(file_stem: str, name: str) -> str:
    raw = f"{file_stem}::{name}"
    return re.sub(r'[^\w:.]', '_', raw)

def extract_python(path: Path) -> dict:
    """Extract nodes + edges from one .py file using Python's ast module."""
    nodes: list[dict] = []
    edges: list[dict] = []
    seen_ids: set[str] = set()
    stem = path.stem

    try:
        src = path.read_text(encoding='utf-8', errors='replace')
        tree = _ast.parse(src, filename=str(path))
    except SyntaxError:
        return {'nodes': [], 'edges': [], 'error': 'syntax_error'}

    # file-level node
    file_id = stem
    nodes.append({'id': file_id, 'label': path.name,
                  'type': 'file', 'source_file': str(path)})
    seen_ids.add(file_id)

    for node in _ast.walk(tree):
        # class
        if isinstance(node, _ast.ClassDef):
            nid = _make_id(stem, node.name)
            if nid not in seen_ids:
                nodes.append({'id': nid, 'label': node.name,
                              'type': 'class', 'source_file': str(path),
                              'line': node.lineno})
                seen_ids.add(nid)
                edges.append({'from': file_id, 'to': nid,
                              'label': 'contains', 'confidence': 'EXTRACTED'})
            # base classes
            for base in node.bases:
                b = _safe_name(base)
                if b:
                    bid = _make_id(stem, b)
                    edges.append({'from': nid, 'to': bid,
                                  'label': 'inherits', 'confidence': 'EXTRACTED'})
            # methods
            for item in node.body:
                if isinstance(item, _ast.FunctionDef):
                    mid = _make_id(stem, f"{node.name}.{item.name}")
                    if mid not in seen_ids:
                        nodes.append({'id': mid, 'label': f".{item.name}()",
                                      'type': 'method', 'source_file': str(path),
                                      'line': item.lineno})
                        seen_ids.add(mid)
                        edges.append({'from': nid, 'to': mid,
                                      'label': 'contains', 'confidence': 'EXTRACTED'})

        # top-level function
        elif isinstance(node, _ast.FunctionDef) and isinstance(
                getattr(node, 'parent', None), (_ast.Module, type(None))):
            fid = _make_id(stem, node.name)
            if fid not in seen_ids:
                nodes.append({'id': fid, 'label': f"{node.name}()",
                              'type': 'function', 'source_file': str(path),
                              'line': node.lineno})
                seen_ids.add(fid)
                edges.append({'from': file_id, 'to': fid,
                              'label': 'contains', 'confidence': 'EXTRACTED'})

        # imports → inferred edges between files
        elif isinstance(node, _ast.Import):
            for alias in node.names:
                target = alias.name.split('.')[0]
                edges.append({'from': file_id, 'to': target,
                              'label': 'imports', 'confidence': 'INFERRED'})
        elif isinstance(node, _ast.ImportFrom):
            if node.module:
                target = node.module.split('.')[0]
                edges.append({'from': file_id, 'to': target,
                              'label': 'imports', 'confidence': 'INFERRED'})

        # function calls
        elif isinstance(node, _ast.Call):
            callee = _safe_name(node.func)
            if callee:
                cid = _make_id(stem, callee)
                edges.append({'from': file_id, 'to': cid,
                              'label': 'calls', 'confidence': 'INFERRED',
                              'confidence_score': 0.6})

    # parent-mark top-level nodes (simple pass to mark FunctionDef at module level)
    for child in _ast.walk(tree):
        for grandchild in _ast.iter_child_nodes(child):
            grandchild.parent = child  # type: ignore[attr-defined]

    return {'nodes': nodes, 'edges': edges}


# ── 2. BUILD (mirrors graphify/build.py) ──

def build_graph(extractions: list[dict]) -> nx.DiGraph:
    G = nx.DiGraph()
    for ex in extractions:
        for n in ex.get('nodes', []):
            nid = n.get('id')
            if nid:
                G.add_node(nid, **{k: v for k, v in n.items() if k != 'id'})
        for e in ex.get('edges', []):
            src, tgt = e.get('from'), e.get('to')
            if src and tgt:
                G.add_edge(src, tgt, **{k: v for k, v in e.items()
                                         if k not in ('from', 'to')})
    return G


# ── 3. CLUSTER (mirrors graphify/cluster.py — Louvain fallback) ──

def cluster(G: nx.DiGraph) -> tuple[dict[int, list[str]], dict[int, float]]:
    """Returns (communities {cid: [node_ids]}, cohesion {cid: float})."""
    Gu = G.to_undirected()
    if len(Gu) == 0:
        return {}, {}

    # Louvain (networkx ≥ 2.7, always available)
    try:
        import inspect
        kwargs: dict = {'seed': 42, 'threshold': 1e-4}
        if 'max_level' in inspect.signature(
                nx.community.louvain_communities).parameters:
            kwargs['max_level'] = 10
        parts = nx.community.louvain_communities(Gu, **kwargs)
        communities: dict[int, list[str]] = {
            cid: list(nodes) for cid, nodes in enumerate(parts)}
    except Exception:
        # absolute fallback: one big community
        communities = {0: list(G.nodes())}

    # cohesion = internal_edges / possible_internal_edges
    cohesion: dict[int, float] = {}
    for cid, members in communities.items():
        sub = Gu.subgraph(members)
        n = len(members)
        possible = n * (n - 1) / 2 if n > 1 else 1
        cohesion[cid] = round(len(sub.edges()) / possible, 4)

    return communities, cohesion


# ── 4. ANALYZE (mirrors graphify/analyze.py) ──

_BUILTINS = frozenset({
    'str','int','float','bool','list','dict','set','tuple',
    'os','sys','re','json','io','abc','typing','Path',
    'Any','Optional','List','Dict','Union','Callable',
})

def god_nodes(G: nx.DiGraph, top_n: int = 8) -> list[dict]:
    """Highest degree nodes excluding builtins + file stubs."""
    scored = []
    for nid in G.nodes():
        label = G.nodes[nid].get('label', nid)
        if label in _BUILTINS:
            continue
        if label.endswith('()') and G.degree(nid) <= 1:
            continue
        scored.append({'id': nid, 'label': label,
                       'degree': G.degree(nid),
                       'in': G.in_degree(nid),
                       'out': G.out_degree(nid)})
    scored.sort(key=lambda x: x['degree'], reverse=True)
    return scored[:top_n]

def surprise_edges(G: nx.DiGraph, communities: dict[int, list[str]],
                   top_n: int = 6) -> list[dict]:
    """Cross-community edges — unexpected structural bridges."""
    node_to_cid = {n: cid for cid, ns in communities.items() for n in ns}
    cross = []
    for src, tgt, data in G.edges(data=True):
        if node_to_cid.get(src) != node_to_cid.get(tgt):
            sl = G.nodes[src].get('label', src)
            tl = G.nodes[tgt].get('label', tgt)
            cross.append({'from': sl, 'to': tl,
                          'rel': data.get('label', '→'),
                          'confidence': data.get('confidence', 'INFERRED')})
    return cross[:top_n]

def community_labels(G: nx.DiGraph,
                     communities: dict[int, list[str]]) -> dict[int, str]:
    """Label each community by its highest-degree internal member."""
    labels = {}
    for cid, members in communities.items():
        if not members:
            labels[cid] = f'cluster_{cid}'
            continue
        hub = max(members, key=lambda n: G.degree(n))
        labels[cid] = G.nodes[hub].get('label', hub)
    return labels


# ── 5. REPORT (mirrors graphify/report.py) ──

def generate_report(G: nx.DiGraph,
                    communities: dict[int, list[str]],
                    cohesion: dict[int, float],
                    com_labels: dict[int, str],
                    gods: list[dict],
                    surprises: list[dict],
                    root: str) -> str:
    today = date.today().isoformat()
    lines = [
        f"# ZULU Graph Report",
        f"",
        f"Generated: {today}  |  Root: `{root}`  |  "
        f"Nodes: {G.number_of_nodes()}  |  Edges: {G.number_of_edges()}",
        f"",
        f"---",
        f"",
        f"## Communities ({len(communities)} clusters)",
    ]
    for cid in sorted(communities):
        members = communities[cid]
        label = com_labels.get(cid, f'cluster_{cid}')
        score = cohesion.get(cid, 0)
        top = sorted(members, key=lambda n: G.degree(n), reverse=True)[:4]
        top_labels = ', '.join(
            f"`{G.nodes[n].get('label', n)}`" for n in top)
        lines.append(
            f"- **{label}** ({len(members)} nodes, cohesion={score}) — {top_labels}")

    lines += ["", "---", "", "## God Nodes (most connected)"]
    for g in gods:
        lines.append(
            f"- `{g['label']}` — degree {g['degree']} "
            f"(in={g['in']}, out={g['out']})")

    if surprises:
        lines += ["", "---", "",
                  "## Surprising Connections (cross-community bridges)"]
        for s in surprises:
            lines.append(
                f"- `{s['from']}` **{s['rel']}** `{s['to']}` "
                f"({s['confidence'].lower()})")

    lines += ["", "---", "",
              "## Suggested Questions",
              "- Which god node is the riskiest single point of failure?",
              "- Why do these cross-community bridges exist?",
              "- Which clusters have low cohesion and might need refactoring?",
              "- What would break if the top god node was removed?",
              "", "_Generated by ZuluGraphEngine — graphify core pipeline_"]

    return '\n'.join(lines)


# ── 6. MAIN ENGINE CLASS ──

class ZuluGraphEngine:
    """
    Drop-in graphify core for the ZULU AI OS.

    engine = ZuluGraphEngine('/path/to/project')
    md     = engine.run()        # scan + build + cluster + report (markdown)
    engine.save('graphify-out/') # write graph.json + GRAPH_REPORT.md
    nodes  = engine.god_nodes    # list[dict]
    data   = engine.graph_json() # full graph as dict (for /graph endpoint)
    """

    def __init__(self, root: str | Path = '.'):
        self.root = Path(root).resolve()
        self.G: nx.DiGraph = nx.DiGraph()
        self.communities: dict[int, list[str]] = {}
        self.cohesion: dict[int, float] = {}
        self.com_labels: dict[int, str] = {}
        self.god_nodes: list[dict] = []
        self.surprises: list[dict] = []
        self._report: str = ''
        self._built = False

    def scan(self, extensions: tuple[str, ...] = ('.py',),
             exclude: tuple[str, ...] = ('__pycache__', '.git',
                                          'node_modules', 'venv', '.venv',
                                          'graphify-out')) -> list[dict]:
        """Walk root, extract AST from each matching file."""
        extractions: list[dict] = []
        for path in sorted(self.root.rglob('*')):
            if any(ex in path.parts for ex in exclude):
                continue
            if path.suffix not in extensions:
                continue
            ex = extract_python(path)
            # make paths relative for clean node IDs
            for n in ex['nodes']:
                if 'source_file' in n:
                    try:
                        n['source_file'] = str(
                            Path(n['source_file']).relative_to(self.root))
                    except ValueError:
                        pass
            extractions.append(ex)
        return extractions

    def run(self, extensions: tuple[str, ...] = ('.py',)) -> str:
        """Full pipeline. Returns markdown report string."""
        extractions = self.scan(extensions)
        self.G = build_graph(extractions)
        self.communities, self.cohesion = cluster(self.G)
        self.com_labels = community_labels(self.G, self.communities)
        self.god_nodes = god_nodes(self.G)
        self.surprises = surprise_edges(self.G, self.communities)
        self._report = generate_report(
            self.G, self.communities, self.cohesion,
            self.com_labels, self.god_nodes, self.surprises,
            str(self.root))
        self._built = True
        return self._report

    def save(self, out_dir: str | Path = 'graphify-out') -> Path:
        """Write graph.json + GRAPH_REPORT.md to out_dir."""
        if not self._built:
            self.run()
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)
        # graph.json
        gj = out / 'graph.json'
        gj.write_text(json.dumps(self.graph_json(), indent=2,
                                  ensure_ascii=False), encoding='utf-8')
        # GRAPH_REPORT.md
        rp = out / 'GRAPH_REPORT.md'
        rp.write_text(self._report, encoding='utf-8')
        return out

    def graph_json(self) -> dict:
        """Serializable graph dict compatible with graphify's graph.json schema."""
        nodes = []
        for nid, attrs in self.G.nodes(data=True):
            nodes.append({'id': nid, **attrs})
        edges = []
        for src, tgt, attrs in self.G.edges(data=True):
            edges.append({'from': src, 'to': tgt, **attrs})
        cid_map = {n: cid for cid, ns in self.communities.items() for n in ns}
        for n in nodes:
            n['community'] = cid_map.get(n['id'])
            n['community_label'] = self.com_labels.get(n.get('community', -1), '')
        return {
            'meta': {
                'root': str(self.root),
                'nodes': self.G.number_of_nodes(),
                'edges': self.G.number_of_edges(),
                'communities': len(self.communities),
                'generated': date.today().isoformat(),
                'engine': 'ZuluGraphEngine v1.0',
            },
            'nodes': nodes,
            'edges': edges,
            'communities': {str(k): v for k, v in self.communities.items()},
            'community_labels': {str(k): v for k, v in self.com_labels.items()},
            'god_nodes': self.god_nodes,
            'surprises': self.surprises,
        }

    def query(self, question: str) -> str:
        """Simple keyword query against node labels + community names."""
        if not self._built:
            return 'Graph not built yet. Call engine.run() first.'
        q = question.lower()
        hits: list[str] = []
        # match nodes
        for nid, attrs in self.G.nodes(data=True):
            label = attrs.get('label', nid).lower()
            if any(w in label for w in q.split()):
                deg = self.G.degree(nid)
                src = attrs.get('source_file', '')
                hits.append(f"- `{attrs.get('label', nid)}` "
                            f"(degree={deg}, file={src})")
        if not hits:
            return f'No nodes matched "{question}". Try a class or function name.'
        return f'Nodes matching "{question}":\n' + '\n'.join(hits[:12])


# ── 7. FLASK ENDPOINTS (add to zulu_server.py) ──

def register_graph_routes(app, project_root: str = '.'):
    """
    Call this from zulu_server.py:
        from zulu_graph import register_graph_routes
        register_graph_routes(app, project_root='/path/to/zulu')

    Adds:
        POST /graph/build      — scan + build, returns summary JSON
        GET  /graph/report     — returns GRAPH_REPORT.md text
        GET  /graph/json       — returns full graph.json
        POST /graph/query      — body: {"question":"..."} → node matches
    """
    from flask import jsonify, request as freq

    _engine: list[ZuluGraphEngine] = []  # mutable closure

    def _get_engine() -> ZuluGraphEngine:
        if not _engine:
            _engine.append(ZuluGraphEngine(project_root))
        return _engine[0]

    @app.route('/graph/build', methods=['POST'])
    def graph_build():
        try:
            eng = ZuluGraphEngine(project_root)
            _engine.clear()
            _engine.append(eng)
            report = eng.run()
            eng.save('graphify-out')
            return jsonify({
                'ok': True,
                'nodes': eng.G.number_of_nodes(),
                'edges': eng.G.number_of_edges(),
                'communities': len(eng.communities),
                'god_nodes': [g['label'] for g in eng.god_nodes],
            })
        except Exception as e:
            return jsonify({'ok': False, 'error': str(e)}), 500

    @app.route('/graph/report', methods=['GET'])
    def graph_report():
        eng = _get_engine()
        if not eng._built:
            eng.run(); eng.save('graphify-out')
        return eng._report, 200, {'Content-Type': 'text/plain; charset=utf-8'}

    @app.route('/graph/json', methods=['GET'])
    def graph_json_route():
        eng = _get_engine()
        if not eng._built:
            eng.run()
        return jsonify(eng.graph_json())

    @app.route('/graph/query', methods=['POST'])
    def graph_query():
        eng = _get_engine()
        if not eng._built:
            eng.run()
        q = freq.get_json(silent=True) or {}
        question = q.get('question', '').strip()
        if not question:
            return jsonify({'error': 'question required'}), 400
        return jsonify({'answer': eng.query(question)})
