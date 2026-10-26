/++
yaml-edit: comment- and format-preserving (round-trip) YAML editing for D.

The parser is lossless: the document is kept as its original lines (text plus
line ending), and a concrete syntax tree records where every key, value and
sequence item lives. Edits splice only the lines or columns they touch, so
everything else is emitted byte for byte.

v1 scope: block mappings and block sequences, plain / single-quoted /
double-quoted scalars (single- and multi-line), literal and folded block
scalars, comments, blank lines, directives and a single `---` / `...`
document. Flow collections, anchors, aliases and tags are preserved as opaque
regions; multiple documents raise `YamlEditException`.
+/
module yaml_edit;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : appender, replace, split;
import std.conv : to, text;
import std.string : indexOf, strip, stripLeft, stripRight;

/// Thrown for unsupported or malformed input and for invalid edits.
class YamlEditException : Exception
{
    /// 1-based line number, or 0 when not tied to a line.
    size_t line;

    this(string msg, size_t line = 0, string file = __FILE__, size_t ln = __LINE__) @safe pure
    {
        super(line ? text("line ", line, ": ", msg) : msg, file, ln);
        this.line = line;
    }
}

/// Kind of node at a path.
enum NodeKind
{
    null_,    /// key or item with no value at all (`key:`)
    scalar,   /// plain, quoted or block scalar
    mapping,  /// block mapping
    sequence, /// block sequence
    opaque,   /// preserved but not interpreted: flow collection, anchor, alias, tag
}

/// Scalar presentation style.
enum ScalarStyle
{
    /**
    Keep an existing value's style. A new scalar takes the most common style
    among its sibling scalars (plain, single or double quotes; a tie goes to
    the nearest sibling), then among values under the same key in the
    document, then any scalar in the document, else plain. Quotes a sibling
    needs only because of its content (`'@x'`, `'yes'`) do not count. Values
    that are not plain-safe or would change type as plain are still quoted.
    */
    preserve,
    plain,
    singleQuoted,
    doubleQuoted,
    literal,      /// `|` block scalar
    folded,       /// `>` block scalar (read only; writes use `literal`)
}

// ---------------------------------------------------------------------------
// CST
// ---------------------------------------------------------------------------

private struct Line
{
    string text; // without line ending
    string eol;  // "\n", "\r\n" or "" (last line without newline)
}

private final class Node
{
    NodeKind kind;
    size_t first, last; // line indices, inclusive
    size_t indent;      // column of the node's first character
    // scalars
    ScalarStyle style;
    string value;
    bool isNullLiteral;
    bool multiline;
    size_t col0, col1; // value span on line `first` (single-line scalars, flow on one line)
    // opaque
    string opaqueReason;
    bool emptyFlowSeq, emptyFlowMap;
    // collections
    Entry[] entries;
    Item[] items;
}

private struct Slot
{
    size_t head;  // line holding the key or dash
    size_t after; // column right after ':' or '-'
    Node value;   // null when there is no value
}

private final class Entry
{
    string key;
    ScalarStyle keyStyle;
    size_t keyCol;
    Slot slot;
}

private final class Item
{
    size_t dashCol;
    Slot slot;
}

private struct Seg
{
    string key;
    bool isIndex;
    long index;
}

private struct Found
{
    bool ok;
    Node node;
    Slot* slot;
    Node container;
    size_t depth;
}

/// Read-only view of a node. Valid until the next edit of its document.
struct NodeRef
{
    private Node n;

    /// Kind of this node.
    NodeKind kind() { return n is null ? NodeKind.null_ : n.kind; }

    /// True for a missing value or a `~` / `null` literal.
    bool isNull() { return n is null || (n.kind == NodeKind.scalar && n.isNullLiteral); }

    /// Decoded scalar text (null for an empty value).
    string value()
    {
        if (n is null) return null;
        if (n.kind != NodeKind.scalar)
            throw new YamlEditException(text("not a scalar but ", aKind(n)), n.first + 1);
        return n.value;
    }

    /// Presentation style of a scalar.
    ScalarStyle style() { return n is null ? ScalarStyle.plain : n.style; }

    /// Why an opaque node was not interpreted (e.g. "flow collection").
    string opaqueReason() { return n is null ? null : n.opaqueReason; }

    /// 1-based first line of the node, 0 for an empty value.
    size_t line() { return n is null ? 0 : n.first + 1; }

    /// Keys of a mapping, in document order.
    string[] keys()
    {
        string[] r;
        if (n !is null && n.kind == NodeKind.mapping)
            foreach (e; n.entries) r ~= e.key;
        return r;
    }

    /// Quoting style of each mapping key, parallel to `keys`.
    ScalarStyle[] keyStyles()
    {
        ScalarStyle[] r;
        if (n !is null && n.kind == NodeKind.mapping)
            foreach (e; n.entries) r ~= e.keyStyle;
        return r;
    }

    /// Number of entries (mapping) or items (sequence).
    size_t length()
    {
        if (n is null) return 0;
        if (n.kind == NodeKind.mapping) return n.entries.length;
        if (n.kind == NodeKind.sequence) return n.items.length;
        return 0;
    }

    /// True when a mapping has `key`.
    bool has(string key)
    {
        if (n is null || n.kind != NodeKind.mapping) return false;
        foreach (e; n.entries) if (e.key == key) return true;
        return false;
    }

    /// Child of a mapping.
    NodeRef opIndex(string key)
    {
        if (n !is null && n.kind == NodeKind.mapping)
            foreach (e; n.entries) if (e.key == key) return NodeRef(e.slot.value);
        throw new YamlEditException("no key '" ~ key ~ "'", line);
    }

    /// Item of a sequence.
    NodeRef opIndex(size_t i)
    {
        if (n !is null && n.kind == NodeKind.sequence && i < n.items.length)
            return NodeRef(n.items[i].slot.value);
        throw new YamlEditException(text("no item ", i), line);
    }
}

private string aKind(Node n)
{
    if (n is null) return "a null value";
    if (n.kind == NodeKind.opaque) return "an unsupported " ~ n.opaqueReason ~ " (preserved as opaque)";
    return "a " ~ kindName(n.kind);
}

private string kindName(NodeKind k)
{
    final switch (k)
    {
    case NodeKind.null_: return "null value";
    case NodeKind.scalar: return "scalar";
    case NodeKind.mapping: return "mapping";
    case NodeKind.sequence: return "sequence";
    case NodeKind.opaque: return "opaque node";
    }
}

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

/// A parsed YAML document that can be edited and emitted losslessly.
final class Document
{
    private Line[] lines;
    private string bom;
    private string nl = "\n";
    private Node root_;
    private size_t bodyStart, bodyEnd;
    private size_t step = 2;
    private bool stepKnown;
    private long seqOffset = -1;

    private this() {}

    /// Parse YAML text. Throws `YamlEditException` on unsupported or invalid input.
    static Document parse(string src)
    {
        auto d = new Document;
        d.load(src);
        return d;
    }

    /// Parse a file.
    static Document parseFile(string path)
    {
        import std.file : read;
        return parse(cast(string) read(path));
    }

    /// The document text. Untouched regions are byte-identical to the input.
    string emit() const
    {
        auto a = appender!string;
        a.put(bom);
        foreach (l; lines) { a.put(l.text); a.put(l.eol); }
        return a.data;
    }

    override string toString() const { return emit(); }

    /// Write `emit()` to a file.
    void save(string path) const
    {
        import std.file : write;
        write(path, emit());
    }

    /// Root node view.
    NodeRef root() { return NodeRef(root_); }

    /// Node at a dotted path such as `ui.bundle.url` or `antora.extensions[0].require`.
    NodeRef node(string path)
    {
        auto segs = parsePath(path);
        auto f = walk(segs);
        if (!f.ok) throw notFound(path, f);
        return NodeRef(f.node);
    }

    /// True when the path exists (an empty value counts as existing).
    bool has(string path) { return walk(parsePath(path)).ok; }

    /// Kind of node at the path.
    NodeKind kind(string path) { return node(path).kind; }

    /// Decoded scalar value at the path.
    string get(string path) { return node(path).value; }

    /// Decoded scalar value, or `fallback` when the path does not exist.
    string get(string path, string fallback)
    {
        auto f = walk(parsePath(path));
        if (!f.ok) return fallback;
        return NodeRef(f.node).value;
    }

    /// Keys of the mapping at the path.
    string[] keys(string path) { return node(path).keys; }

    /// Number of items or entries at the path.
    size_t length(string path) { return node(path).length; }

    // ----------------------------------------------------------------- edits

    /**
    Set a scalar value, creating missing mapping keys along the path.
    With `ScalarStyle.preserve` the existing quoting is kept; new values copy
    the quoting of a sibling, and otherwise use plain style when that cannot
    change the value's type (else single quotes). Pass `ScalarStyle.plain` to
    write typed values such as `true` or `42` unquoted.
    */
    void set(string path, string value, ScalarStyle style = ScalarStyle.preserve)
    {
        auto segs = parsePath(path);
        if (segs.length == 0) throw new YamlEditException("cannot set the document root");
        auto f = walk(segs);
        if (!f.ok)
        {
            createPath(segs, f, value, style, false);
            return;
        }
        auto st = resolveStyle(value, style, f.node, ScalarStyle.preserve);
        writeSlot(f.slot, f.container.indent, value, st, false);
    }

    /**
    Set `path` to an empty collection: `[]` for `NodeKind.sequence`, `{}` for
    `NodeKind.mapping`. Items or keys can then be added to it.
    */
    void setEmpty(string path, NodeKind kind)
    {
        if (kind != NodeKind.sequence && kind != NodeKind.mapping)
            throw new YamlEditException("setEmpty needs NodeKind.sequence or NodeKind.mapping");
        string v = kind == NodeKind.sequence ? "[]" : "{}";
        auto segs = parsePath(path);
        if (segs.length == 0) throw new YamlEditException("cannot replace the document root");
        auto f = walk(segs);
        if (!f.ok) { createPath(segs, f, v, ScalarStyle.plain, false, true); return; }
        writeSlot(f.slot, f.container.indent, v, ScalarStyle.plain, true);
    }

    /**
    Replace the value at `path` with verbatim single-line YAML such as
    `[1, 2]` or `{a: b}` (created when missing). The edit is rolled back
    with a YamlEditException when the result does not parse.
    */
    void setRaw(string path, string yaml)
    {
        if (yaml.canFind('\n') || yaml.canFind('\r'))
            throw new YamlEditException("setRaw takes a single line");
        auto segs = parsePath(path);
        if (segs.length == 0) throw new YamlEditException("cannot replace the document root");
        auto f = walk(segs);
        if (!f.ok) { createPath(segs, f, yaml, ScalarStyle.plain, false, true); return; }
        writeSlot(f.slot, f.container.indent, yaml, ScalarStyle.plain, true);
    }

    /// Exact source text of a node (from its first character to its last line).
    string source(NodeRef r) const
    {
        auto n = r.n;
        if (n is null) return null;
        auto a = appender!string;
        foreach (li; n.first .. n.last + 1)
        {
            if (li > n.first) a.put("\n");
            a.put(li == n.first ? lines[li].text[n.indent .. $] : lines[li].text);
        }
        return a.data;
    }

    /// Remove a mapping key or sequence item. Returns false when the path does not exist.
    bool remove(string path)
    {
        auto segs = parsePath(path);
        if (segs.length == 0) throw new YamlEditException("cannot remove the document root");
        auto f = walk(segs);
        if (!f.ok) return false;
        if (segs[$ - 1].isIndex)
        {
            removeItemAt(segs[0 .. $ - 1], segs[$ - 1].index);
            return true;
        }
        removeEntry(f);
        return true;
    }

    /// Append a scalar item to the block sequence at `path` (created if missing).
    void appendItem(string path, string value, string comment = null)
    {
        insertItemImpl(path, -1, ItemVal(false, value, null), comment);
    }

    /// Append a mapping item, e.g. `[["require", "@x/y"], ["key", "v"]]`.
    void appendItem(string path, string[2][] mapping, string comment = null)
    {
        insertItemImpl(path, -1, ItemVal(true, null, mapping), comment);
    }

    /// Insert a scalar item before `index` (index >= length appends).
    void insertItem(string path, size_t index, string value, string comment = null)
    {
        insertItemImpl(path, cast(long) index, ItemVal(false, value, null), comment);
    }

    /// Insert a mapping item before `index`.
    void insertItem(string path, size_t index, string[2][] mapping, string comment = null)
    {
        insertItemImpl(path, cast(long) index, ItemVal(true, null, mapping), comment);
    }

    /// Remove item `index` of the sequence at `path`. Removing the last item leaves `[]`.
    void removeItem(string path, size_t index)
    {
        removeItemAt(parsePath(path), cast(long) index);
    }

    /**
    Index of the first item whose scalar equals `value` (when `key` is null),
    or whose mapping has `key` equal to `value`; -1 when none.
    */
    long findItem(string path, string value, string key = null)
    {
        auto f = walk(parsePath(path));
        if (!f.ok || f.node is null || f.node.kind != NodeKind.sequence) return -1;
        foreach (i, it; f.node.items)
        {
            auto v = it.slot.value;
            if (v is null) continue;
            if (key is null)
            {
                if (v.kind == NodeKind.scalar && v.value == value) return cast(long) i;
            }
            else if (v.kind == NodeKind.mapping)
            {
                foreach (e; v.entries)
                    if (e.key == key && e.slot.value !is null
                        && e.slot.value.kind == NodeKind.scalar && e.slot.value.value == value)
                        return cast(long) i;
            }
        }
        return -1;
    }

    /// Trailing comment on the key / dash line of `path` (without `#`), or null.
    string comment(string path)
    {
        auto f = requireSlot(path);
        auto s = lines[f.slot.head].text;
        auto tc = findComment(s, f.slot.after);
        if (tc >= s.length) return null;
        auto h = s.indexOf('#', tc);
        return s[h + 1 .. $].strip;
    }

    /// Set (or with null remove) the trailing comment on the key / dash line of `path`.
    void setComment(string path, string comment)
    {
        if (comment.canFind('\n') || comment.canFind('\r'))
            throw new YamlEditException("comments must be a single line");
        auto f = requireSlot(path);
        auto s = lines[f.slot.head].text;
        auto tc = findComment(s, f.slot.after);
        string gap = "  ";
        if (tc < s.length) gap = s[tc .. s.indexOf('#', tc)];
        string base = s[0 .. tc];
        setLine(f.slot.head, comment.length ? base ~ gap ~ "# " ~ comment : base);
    }

    /// Turn a single-line scalar at `path` into a one-item block sequence.
    void toSequence(string path)
    {
        auto f = requireSlot(path);
        auto v = f.node;
        if (v !is null && v.kind == NodeKind.sequence) return;
        if (v is null || v.kind != NodeKind.scalar || v.multiline || v.first != f.slot.head)
            throw new YamlEditException(path ~ ": only a single-line scalar can be converted to a sequence");
        if (f.container.kind != NodeKind.mapping)
            throw new YamlEditException(path ~ ": only mapping values can be converted to a sequence");
        auto s = lines[f.slot.head].text;
        string item = s[v.col0 .. v.col1];
        string headText = s[0 .. v.col0].stripRight ~ s[v.col1 .. $];
        size_t dash = f.container.indent + cast(size_t)(seqOffset >= 0 ? seqOffset : step);
        replaceLines(f.slot.head, f.slot.head + 1, [headText, pad(dash) ~ "- " ~ item]);
    }

    // ------------------------------------------------------------ internals

    private YamlEditException err(string m, size_t li) { return new YamlEditException(m, li + 1); }

    private YamlEditException notFound(string path, Found f)
    {
        if (f.node !is null && f.node.kind == NodeKind.opaque)
            return new YamlEditException(text("path '", path, "' goes through an unsupported ",
                f.node.opaqueReason, " (preserved as opaque)"), f.node.first + 1);
        return new YamlEditException("path not found: " ~ path);
    }

    private Found requireSlot(string path)
    {
        auto segs = parsePath(path);
        if (segs.length == 0) throw new YamlEditException("the document root has no key line");
        auto f = walk(segs);
        if (!f.ok) throw notFound(path, f);
        return f;
    }

    private void load(string src)
    {
        if (src.startsWith("\xEF\xBB\xBF")) { bom = src[0 .. 3]; src = src[3 .. $]; }
        size_t start = 0;
        foreach (i; 0 .. src.length)
        {
            if (src[i] != '\n') continue;
            size_t e = i;
            string eol = "\n";
            if (e > start && src[e - 1] == '\r') { e--; eol = "\r\n"; }
            lines ~= Line(src[start .. e], eol);
            start = i + 1;
        }
        if (start < src.length) lines ~= Line(src[start .. $], "");
        foreach (l; lines) if (l.eol.length) { nl = l.eol; break; }
        reparse();
    }

    private void reparse()
    {
        root_ = null;
        stepKnown = false;
        step = 2;
        seqOffset = -1;
        findBody();
        auto j = nextContent(bodyStart);
        if (j >= bodyEnd) return;
        root_ = parseNode(j, indentOf(j), -1);
        auto k = nextContent(root_.last + 1);
        if (k < bodyEnd) throw err("unexpected content (bad indentation?)", k);
    }

    private static bool isMarker(string t, string m)
    {
        return t.startsWith(m) && (t.length == 3 || t[3] == ' ' || t[3] == '\t');
    }

    private void findBody()
    {
        bodyStart = 0;
        bodyEnd = lines.length;
        bool content, started;
        foreach (i, l; lines)
        {
            auto t = l.text;
            if (!content && !started && t.startsWith("%")) { bodyStart = i + 1; continue; }
            if (isMarker(t, "---"))
            {
                if (content || started)
                    throw err("multiple documents are not supported", i);
                if (!blankOrComment(t[3 .. $]))
                    throw err("content on the '---' line is not supported", i);
                started = true;
                bodyStart = i + 1;
                continue;
            }
            if (isMarker(t, "..."))
            {
                bodyEnd = i;
                foreach (k; i + 1 .. lines.length)
                    if (!blankOrComment(lines[k].text))
                        throw err("multiple documents are not supported", k);
                return;
            }
            if (!blankOrComment(t)) content = true;
        }
    }

    private static bool blankOrComment(string t)
    {
        auto s = t.stripLeft;
        return s.length == 0 || s[0] == '#';
    }

    private static bool isBlank(string t) { return t.strip.length == 0; }

    private size_t indentOf(size_t li)
    {
        auto t = lines[li].text;
        size_t k = 0;
        while (k < t.length && t[k] == ' ') k++;
        if (k < t.length && t[k] == '\t' && !blankOrComment(t))
            throw err("tab character used for indentation", li);
        return k;
    }

    private size_t nextContent(size_t i)
    {
        while (i < bodyEnd && blankOrComment(lines[i].text)) i++;
        return i;
    }

    private static size_t skipWs(string s, size_t c)
    {
        while (c < s.length && (s[c] == ' ' || s[c] == '\t')) c++;
        return c;
    }

    private static bool isDashAt(string s, size_t c)
    {
        return c < s.length && s[c] == '-' && (c + 1 == s.length || s[c + 1] == ' ' || s[c + 1] == '\t');
    }

    private static long closeQuote(string s, size_t from, char q)
    {
        for (size_t i = from; i < s.length; i++)
        {
            if (q == '\'')
            {
                if (s[i] == '\'')
                {
                    if (i + 1 < s.length && s[i + 1] == '\'') { i++; continue; }
                    return cast(long) i;
                }
            }
            else
            {
                if (s[i] == '\\') { i++; continue; }
                if (s[i] == '"') return cast(long) i;
            }
        }
        return -1;
    }

    /// Start of the whitespace run before a trailing comment, or s.length.
    private static size_t findComment(string s, size_t from)
    {
        char q = 0;
        for (size_t i = from; i < s.length; i++)
        {
            char ch = s[i];
            if (q)
            {
                if (q == '\'')
                {
                    if (ch == '\'')
                    {
                        if (i + 1 < s.length && s[i + 1] == '\'') i++;
                        else q = 0;
                    }
                }
                else if (ch == '\\') i++;
                else if (ch == '"') q = 0;
                continue;
            }
            bool atStart = i == from || " \t[{,".canFind(s[i - 1]);
            if ((ch == '\'' || ch == '"') && atStart) { q = ch; continue; }
            if (ch == '#' && i > 0 && (s[i - 1] == ' ' || s[i - 1] == '\t'))
            {
                size_t k = i;
                while (k > from && (s[k - 1] == ' ' || s[k - 1] == '\t')) k--;
                return k;
            }
        }
        return s.length;
    }

    private bool keyAt(string s, size_t c, size_t li, out size_t colon, out string key, out ScalarStyle ks)
    {
        if (c >= s.length) return false;
        char ch = s[c];
        if (ch == '?' && (c + 1 == s.length || s[c + 1] == ' ' || s[c + 1] == '\t'))
            throw err("explicit '?' keys are not supported", li);
        if (ch == '[' || ch == '{' || ch == '|' || ch == '>' || ch == '#') return false;
        if (isDashAt(s, c)) return false;
        if (ch == '"' || ch == '\'')
        {
            auto e = closeQuote(s, c + 1, ch);
            if (e < 0) return false;
            auto j = skipWs(s, cast(size_t) e + 1);
            if (j < s.length && s[j] == ':' && (j + 1 == s.length || s[j + 1] == ' ' || s[j + 1] == '\t'))
            {
                colon = j;
                auto raw = s[c + 1 .. cast(size_t) e];
                key = ch == '"' ? unescapeDouble(raw, li) : raw.replace("''", "'");
                ks = ch == '"' ? ScalarStyle.doubleQuoted : ScalarStyle.singleQuoted;
                return true;
            }
            return false;
        }
        for (size_t j = c; j < s.length; j++)
        {
            if (s[j] == '#' && j > c && (s[j - 1] == ' ' || s[j - 1] == '\t')) return false;
            if (s[j] == ':' && (j + 1 == s.length || s[j + 1] == ' ' || s[j + 1] == '\t'))
            {
                if (ch == '&' || ch == '!' || ch == '*')
                    throw err("anchors, tags and aliases on keys are not supported", li);
                colon = j;
                key = s[c .. j].stripRight;
                ks = ScalarStyle.plain;
                return true;
            }
        }
        return false;
    }

    private Node parseNode(size_t li, size_t c, long parentIndent)
    {
        auto s = lines[li].text;
        if (isDashAt(s, c)) return parseSeq(li, c);
        size_t colon;
        string key;
        ScalarStyle ks;
        if (keyAt(s, c, li, colon, key, ks)) return parseMap(li, c);
        return parseValue(li, c, parentIndent);
    }

    private Node parseSeq(size_t li, size_t col)
    {
        auto n = new Node;
        n.kind = NodeKind.sequence;
        n.first = li;
        n.indent = col;
        size_t i = li;
        while (true)
        {
            auto s = lines[i].text;
            auto it = new Item;
            it.dashCol = col;
            it.slot.head = i;
            it.slot.after = col + 1;
            auto c2 = skipWs(s, col + 1);
            size_t lastLine = i;
            if (c2 >= s.length || s[c2] == '#')
            {
                auto j = nextContent(i + 1);
                if (j < bodyEnd && indentOf(j) > col)
                    it.slot.value = parseNode(j, indentOf(j), cast(long) col);
            }
            else
                it.slot.value = parseNode(i, c2, cast(long) col);
            if (it.slot.value !is null && it.slot.value.last > lastLine) lastLine = it.slot.value.last;
            n.items ~= it;
            n.last = lastLine;
            auto j = nextContent(lastLine + 1);
            if (j >= bodyEnd) break;
            auto ind = indentOf(j);
            if (ind == col && isDashAt(lines[j].text, col)) { i = j; continue; }
            if (ind > col) throw err("unexpected indentation in sequence", j);
            break;
        }
        return n;
    }

    private Node parseMap(size_t li, size_t col)
    {
        auto n = new Node;
        n.kind = NodeKind.mapping;
        n.first = li;
        n.indent = col;
        size_t i = li;
        while (true)
        {
            auto s = lines[i].text;
            auto e = new Entry;
            size_t colon;
            if (!keyAt(s, col, i, colon, e.key, e.keyStyle))
                throw err("expected a mapping key", i);
            e.keyCol = col;
            e.slot.head = i;
            e.slot.after = colon + 1;
            auto c2 = skipWs(s, colon + 1);
            if (c2 >= s.length || s[c2] == '#')
            {
                auto j = nextContent(i + 1);
                if (j < bodyEnd)
                {
                    auto ind = indentOf(j);
                    if (ind > col)
                    {
                        e.slot.value = parseNode(j, ind, cast(long) col);
                        auto v = e.slot.value;
                        if (v.kind == NodeKind.mapping && !stepKnown) { step = ind - col; stepKnown = true; }
                        if (v.kind == NodeKind.sequence && seqOffset < 0) seqOffset = cast(long)(ind - col);
                    }
                    else if (ind == col && isDashAt(lines[j].text, col))
                    {
                        e.slot.value = parseSeq(j, col);
                        if (seqOffset < 0) seqOffset = 0;
                    }
                }
            }
            else
                e.slot.value = parseValue(i, c2, cast(long) col);
            n.entries ~= e;
            size_t lastLine = i;
            if (e.slot.value !is null && e.slot.value.last > lastLine) lastLine = e.slot.value.last;
            n.last = lastLine;
            auto j = nextContent(lastLine + 1);
            if (j >= bodyEnd) break;
            auto ind = indentOf(j);
            if (ind == col)
            {
                if (isDashAt(lines[j].text, col)) break; // parent sequence continues (indentless)
                i = j;
                continue;
            }
            if (ind > col) throw err("unexpected indentation in mapping", j);
            break;
        }
        return n;
    }

    private size_t extentDeeper(size_t li, long parentIndent)
    {
        size_t last = li;
        for (size_t j = li + 1; j < bodyEnd; j++)
        {
            if (blankOrComment(lines[j].text)) continue;
            if (cast(long) indentOf(j) > parentIndent) last = j;
            else break;
        }
        return last;
    }

    private void checkTrailing(string s, size_t from, size_t li)
    {
        auto j = skipWs(s, from);
        if (j < s.length && (s[j] != '#' || j == from))
            throw err("unexpected text after value", li);
    }

    private Node parseValue(size_t li, size_t c, long parentIndent)
    {
        auto s = lines[li].text;
        auto n = new Node;
        n.first = n.last = li;
        n.indent = c;
        char ch = s[c];
        switch (ch)
        {
        case '|':
        case '>':
            return parseBlockScalar(n, li, c, parentIndent);
        case '[':
        case '{':
            return parseFlow(n, li, c);
        case '&':
        case '!':
        case '*':
            n.kind = NodeKind.opaque;
            n.opaqueReason = ch == '&' ? "anchor" : ch == '!' ? "tag" : "alias";
            n.last = extentDeeper(li, parentIndent);
            return n;
        case '"':
        case '\'':
            return parseQuoted(n, li, c);
        case '@':
        case '`':
        case '%':
            throw err("a plain scalar cannot start with '" ~ ch ~ "'", li);
        default:
            return parsePlain(n, li, c, parentIndent);
        }
    }

    private static size_t plainEnd(string s, size_t c)
    {
        for (size_t j = c + 1; j < s.length; j++)
            if (s[j] == '#' && (s[j - 1] == ' ' || s[j - 1] == '\t')) return j;
        return s.length;
    }

    private Node parsePlain(Node n, size_t li, size_t c, long parentIndent)
    {
        auto s = lines[li].text;
        n.kind = NodeKind.scalar;
        n.style = ScalarStyle.plain;
        auto pe = plainEnd(s, c);
        string first = s[c .. pe].stripRight;
        n.col0 = c;
        n.col1 = c + first.length;
        if (first.canFind(": ") || first.canFind(":\t") || first.endsWith(":"))
            throw err("mapping values are not allowed here", li);
        string[] parts = [first];
        bool commentHit = pe < s.length;
        size_t j = li + 1;
        while (!commentHit)
        {
            size_t k = j, blanks = 0;
            while (k < bodyEnd && isBlank(lines[k].text)) { k++; blanks++; }
            if (k >= bodyEnd) break;
            auto t = lines[k].text;
            if (blankOrComment(t)) break;
            if (cast(long) indentOf(k) <= parentIndent) break;
            auto ci = skipWs(t, 0);
            size_t dc;
            string dk;
            ScalarStyle dks;
            if (keyAt(t, ci, k, dc, dk, dks))
                throw err("mapping values are not allowed here (bad indentation?)", k);
            auto e2 = plainEnd(t, ci);
            foreach (_; 0 .. blanks) parts ~= null;
            parts ~= t[ci .. e2].stripRight;
            n.last = k;
            j = k + 1;
            if (e2 < t.length) commentHit = true;
        }
        if (n.last > li)
        {
            n.multiline = true;
            auto a = appender!string;
            a.put(parts[0]);
            size_t empties = 0;
            foreach (p; parts[1 .. $])
            {
                if (p is null) { empties++; continue; }
                if (empties) foreach (_; 0 .. empties) a.put('\n');
                else a.put(' ');
                a.put(p);
                empties = 0;
            }
            n.value = a.data;
        }
        else
            n.value = first;
        n.isNullLiteral = !n.multiline && (first == "~" || first == "null" || first == "Null" || first == "NULL");
        return n;
    }

    private Node parseQuoted(Node n, size_t li, size_t c)
    {
        auto s = lines[li].text;
        char q = s[c];
        bool dbl = q == '"';
        n.kind = NodeKind.scalar;
        n.style = dbl ? ScalarStyle.doubleQuoted : ScalarStyle.singleQuoted;
        auto e = closeQuote(s, c + 1, q);
        if (e >= 0)
        {
            n.col0 = c;
            n.col1 = cast(size_t) e + 1;
            checkTrailing(s, n.col1, li);
            auto raw = s[c + 1 .. cast(size_t) e];
            n.value = dbl ? unescapeDouble(raw, li) : raw.replace("''", "'");
            return n;
        }
        string[] segs = [s[c + 1 .. $]];
        size_t k = li + 1;
        while (true)
        {
            if (k >= bodyEnd) throw err("unterminated quoted scalar", li);
            auto t = lines[k].text;
            auto e2 = closeQuote(t, 0, q);
            if (e2 >= 0)
            {
                segs ~= t[0 .. cast(size_t) e2];
                checkTrailing(t, cast(size_t) e2 + 1, k);
                break;
            }
            segs ~= t;
            k++;
        }
        n.multiline = true;
        n.last = k;
        auto folded = foldQuoted(segs, dbl);
        n.value = dbl ? unescapeDouble(folded, li) : folded.replace("''", "'");
        return n;
    }

    private static bool oddBackslashes(string s)
    {
        size_t c = 0;
        while (c < s.length && s[$ - 1 - c] == '\\') c++;
        return (c & 1) == 1;
    }

    private static string foldQuoted(string[] segs, bool dbl)
    {
        auto a = appender!string;
        size_t i = 0;
        string cur = segs[0];
        while (true)
        {
            if (i == segs.length - 1) { a.put(cur); break; }
            bool escaped = dbl && oddBackslashes(cur);
            a.put(escaped ? cur[0 .. $ - 1] : cur.stripRight);
            size_t j = i + 1, empties = 0;
            while (j < segs.length - 1 && segs[j].strip.length == 0) { empties++; j++; }
            foreach (_; 0 .. empties) a.put('\n');
            if (!escaped && empties == 0) a.put(' ');
            i = j;
            cur = segs[i].stripLeft;
        }
        return a.data;
    }

    private Node parseBlockScalar(Node n, size_t li, size_t c, long parentIndent)
    {
        auto s = lines[li].text;
        n.kind = NodeKind.scalar;
        n.style = s[c] == '|' ? ScalarStyle.literal : ScalarStyle.folded;
        n.multiline = true;
        size_t h = c + 1;
        char chomp = 'c';
        size_t explicitInd = 0;
        while (h < s.length && s[h] != ' ' && s[h] != '\t')
        {
            if (s[h] == '-') chomp = 's';
            else if (s[h] == '+') chomp = 'k';
            else if (s[h] >= '1' && s[h] <= '9') explicitInd = s[h] - '0';
            else throw err("invalid block scalar header", li);
            h++;
        }
        checkTrailing(s, h, li);
        n.col0 = c;
        n.col1 = h;
        long base = parentIndent;
        size_t ci = 0;
        bool ciKnown = false;
        if (explicitInd) { ci = cast(size_t)(parentIndent < 0 ? 0 : parentIndent) + explicitInd; ciKnown = true; }
        size_t k = li + 1, lastNonBlank = li;
        for (; k < bodyEnd; k++)
        {
            auto t = lines[k].text;
            if (isBlank(t)) continue;
            size_t ind = 0;
            while (ind < t.length && t[ind] == ' ') ind++;
            if (!ciKnown)
            {
                if (cast(long) ind <= base) break;
                ci = ind;
                ciKnown = true;
            }
            if (ind < ci)
            {
                if (cast(long) ind <= base) break;
                throw err("bad indentation in block scalar", k);
            }
            lastNonBlank = k;
        }
        n.last = lastNonBlank;
        size_t trailing = 0;
        for (size_t t = lastNonBlank + 1; t < k && t < bodyEnd && isBlank(lines[t].text); t++) trailing++;
        string[] content;
        bool[] empty;
        foreach (t; li + 1 .. lastNonBlank + 1)
        {
            auto tx = lines[t].text;
            if (tx.length <= ci && isBlank(tx)) { content ~= ""; empty ~= true; }
            else { content ~= tx[ci .. $]; empty ~= false; }
        }
        auto a = appender!string;
        if (n.style == ScalarStyle.literal)
        {
            foreach (idx, cl; content)
            {
                if (idx) a.put('\n');
                a.put(cl);
            }
        }
        else
        {
            bool havePrev, prevMore;
            size_t empties = 0;
            foreach (idx, cl; content)
            {
                if (empty[idx]) { empties++; continue; }
                bool more = cl.length && (cl[0] == ' ' || cl[0] == '\t');
                if (!havePrev) foreach (_; 0 .. empties) a.put('\n');
                else if (!prevMore && !more)
                {
                    if (empties == 0) a.put(' ');
                    else foreach (_; 0 .. empties) a.put('\n');
                }
                else foreach (_; 0 .. empties + 1) a.put('\n');
                a.put(cl);
                havePrev = true;
                prevMore = more;
                empties = 0;
            }
        }
        string body_ = a.data;
        bool hasContent = content.length > 0;
        final switch (chomp)
        {
        case 's': n.value = body_; break;
        case 'c': n.value = hasContent ? body_ ~ "\n" : ""; break;
        case 'k':
            auto b = appender!string;
            b.put(body_);
            if (hasContent) b.put('\n');
            foreach (_; 0 .. trailing) b.put('\n');
            n.value = b.data;
            break;
        }
        return n;
    }

    private Node parseFlow(Node n, size_t li, size_t c)
    {
        n.kind = NodeKind.opaque;
        n.opaqueReason = "flow collection";
        int depth = 0;
        char inQ = 0;
        size_t k = li, j = c;
        while (k < bodyEnd)
        {
            auto t = lines[k].text;
            for (; j < t.length; j++)
            {
                char ch = t[j];
                if (inQ)
                {
                    if (inQ == '\'')
                    {
                        if (ch == '\'')
                        {
                            if (j + 1 < t.length && t[j + 1] == '\'') j++;
                            else inQ = 0;
                        }
                    }
                    else if (ch == '\\') j++;
                    else if (ch == '"') inQ = 0;
                    continue;
                }
                bool atStart = j == 0 || " \t[{,:".canFind(t[j - 1]);
                if ((ch == '"' || ch == '\'') && atStart) { inQ = ch; continue; }
                if (ch == '#' && j > 0 && (t[j - 1] == ' ' || t[j - 1] == '\t')) break;
                if (ch == '[' || ch == '{') depth++;
                else if (ch == ']' || ch == '}')
                {
                    depth--;
                    if (depth == 0)
                    {
                        checkTrailing(t, j + 1, k);
                        n.last = k;
                        if (k == li)
                        {
                            n.col0 = c;
                            n.col1 = j + 1;
                            if (t[c + 1 .. j].strip.length == 0)
                            {
                                if (t[c] == '[') n.emptyFlowSeq = true;
                                else n.emptyFlowMap = true;
                            }
                        }
                        return n;
                    }
                }
            }
            k++;
            j = 0;
        }
        throw err("unterminated flow collection", li);
    }

    // ----------------------------------------------------------------- paths

    private static Seg[] parsePath(string p)
    {
        Seg[] r;
        size_t i = 0;
        while (i < p.length)
        {
            if (p[i] == '"')
            {
                auto e = p.indexOf('"', i + 1);
                if (e < 0) throw new YamlEditException("bad path (unclosed quote): " ~ p);
                r ~= Seg(p[i + 1 .. e]);
                i = e + 1;
            }
            else
            {
                size_t s = i;
                while (i < p.length && p[i] != '.' && p[i] != '[') i++;
                if (i > s) r ~= Seg(p[s .. i]);
            }
            while (i < p.length && p[i] == '[')
            {
                auto e = p.indexOf(']', i);
                if (e < 0) throw new YamlEditException("bad path (unclosed '['): " ~ p);
                long ix;
                try ix = to!long(p[i + 1 .. e]);
                catch (Exception) throw new YamlEditException("bad path index: " ~ p);
                r ~= Seg(null, true, ix);
                i = e + 1;
            }
            if (i < p.length)
            {
                if (p[i] != '.') throw new YamlEditException("bad path: " ~ p);
                i++;
            }
        }
        return r;
    }

    private Found walk(Seg[] segs)
    {
        Found f;
        f.node = root_;
        foreach (i, sg; segs)
        {
            auto cur = f.node;
            if (cur is null) return f;
            if (!sg.isIndex)
            {
                if (cur.kind != NodeKind.mapping) return f;
                Entry e;
                foreach (x; cur.entries) if (x.key == sg.key) { e = x; break; }
                if (e is null) return f;
                f.slot = &e.slot;
                f.container = cur;
                f.node = e.slot.value;
            }
            else
            {
                if (cur.kind != NodeKind.sequence) return f;
                long ix = sg.index < 0 ? cast(long) cur.items.length + sg.index : sg.index;
                if (ix < 0 || ix >= cast(long) cur.items.length) return f;
                auto it = cur.items[cast(size_t) ix];
                f.slot = &it.slot;
                f.container = cur;
                f.node = it.slot.value;
            }
            f.depth = i + 1;
        }
        f.ok = true;
        return f;
    }

    // ------------------------------------------------------------ rewriting

    private void replaceLines(size_t from, size_t to, string[] texts)
    {
        auto old = lines.dup;
        Line[] nw;
        foreach (t; texts) nw ~= Line(t, nl);
        auto cur = lines.dup;
        if (to > from)
        {
            auto lastEol = cur[to - 1].eol;
            if (nw.length) nw[$ - 1].eol = lastEol;
            else if (lastEol.length == 0 && from > 0) cur[from - 1].eol = "";
        }
        else if (nw.length && from == cur.length && from > 0 && cur[from - 1].eol.length == 0)
        {
            cur[from - 1].eol = nl;
            nw[$ - 1].eol = "";
        }
        lines = cur[0 .. from] ~ nw ~ cur[to .. $];
        try reparse();
        catch (YamlEditException e)
        {
            lines = old;
            reparse();
            throw new YamlEditException("edit would produce YAML this library cannot parse: " ~ e.msg);
        }
    }

    private void setLine(size_t li, string t) { replaceLines(li, li + 1, [t]); }

    private static string pad(size_t n)
    {
        auto a = appender!string;
        foreach (_; 0 .. n) a.put(' ');
        return a.data;
    }

    private void writeSlot(Slot* sl, size_t ownerIndent, string value, ScalarStyle style, bool raw)
    {
        auto v = sl.value;
        auto head = lines[sl.head].text;
        bool block = !raw && (style == ScalarStyle.literal || style == ScalarStyle.folded);
        if (!raw && !block && v !is null && v.kind == NodeKind.scalar && !v.multiline && v.first == sl.head)
        {
            setLine(sl.head, head[0 .. v.col0] ~ fmtInline(value, style) ~ head[v.col1 .. $]);
            return;
        }
        auto tc = findComment(head, sl.after);
        string trail = head[tc .. $];
        string prefix = head[0 .. sl.after];
        size_t delTo = sl.head + 1;
        if (v !is null && v.last + 1 > delTo) delTo = v.last + 1;
        string[] out_;
        if (block)
        {
            auto b = blockLiteral(value, ownerIndent + step, ownerIndent);
            out_ ~= prefix ~ " " ~ b.header ~ trail;
            out_ ~= b.lines;
        }
        else
            out_ ~= prefix ~ " " ~ (raw ? value : fmtInline(value, style)) ~ trail;
        replaceLines(sl.head, delTo, out_);
    }

    private struct Block { string header; string[] lines; }

    private static Block blockLiteral(string value, size_t contentIndent, size_t parentIndent)
    {
        size_t t = 0;
        while (t < value.length && value[$ - 1 - t] == '\n') t++;
        string body_ = value[0 .. $ - t];
        Block b;
        string chomp = t == 0 ? "-" : t == 1 ? "" : "+";
        string ind;
        foreach (l; body_.split('\n'))
            if (l.length) { if (l[0] == ' ') ind = to!string(contentIndent - parentIndent); break; }
        b.header = "|" ~ ind ~ chomp;
        foreach (l; body_.split('\n')) b.lines ~= l.length ? pad(contentIndent) ~ l : "";
        foreach (_; 1 .. t) b.lines ~= "";
        return b;
    }

    private static bool plainSafe(string v)
    {
        if (v.length == 0) return false;
        if (v[0] == ' ' || v[0] == '\t' || v[$ - 1] == ' ' || v[$ - 1] == '\t') return false;
        if ("-?:".canFind(v[0]) && (v.length == 1 || v[1] == ' ' || v[1] == '\t')) return false;
        if (",[]{}#&*!|>'\"%@`".canFind(v[0])) return false;
        if (v.canFind(": ") || v.canFind(":\t") || v.canFind(" #") || v.canFind("\t#") || v.endsWith(":")) return false;
        if (v.startsWith("---") || v.startsWith("...")) return false;
        foreach (char ch; v) if (ch < 0x20 || ch == 0x7f) return false;
        return true;
    }

    /// Would a plain scalar with this text resolve to something other than a string?
    private static bool looksTyped(string v)
    {
        import std.regex : ctRegex, matchFirst;
        static immutable words = ["true", "false", "True", "False", "TRUE", "FALSE", "yes", "no", "Yes", "No",
            "YES", "NO", "on", "off", "On", "Off", "ON", "OFF", "y", "n", "Y", "N", "null", "Null", "NULL", "~",
            "<<", "="];
        foreach (w; words) if (v == w) return true;
        enum num = ctRegex!(`^([-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?|[-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN)|0x[0-9a-fA-F_]+|0o?[0-7_]+|0b[01_]+|[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}.*)$`);
        return !matchFirst(v, num).empty;
    }

    private static ScalarStyle resolveStyle(string value, ScalarStyle requested, Node existing, ScalarStyle neighbour)
    {
        bool hasNl = value.canFind('\n');
        bool blankNl = hasNl && value.strip.length == 0;
        bool ctrl;
        foreach (char ch; value) if ((ch < 0x20 && ch != '\n' && ch != '\t') || ch == 0x7f) ctrl = true;
        if (ctrl || blankNl) return ScalarStyle.doubleQuoted;
        if (requested != ScalarStyle.preserve)
        {
            if (requested == ScalarStyle.folded) requested = ScalarStyle.literal;
            if (hasNl && requested != ScalarStyle.doubleQuoted && requested != ScalarStyle.literal)
                return ScalarStyle.literal;
            if (requested == ScalarStyle.plain && !plainSafe(value)) return ScalarStyle.singleQuoted;
            if (requested == ScalarStyle.literal && !hasNl) return ScalarStyle.literal;
            return requested;
        }
        bool fromExisting = existing !is null && existing.kind == NodeKind.scalar;
        auto base = fromExisting ? existing.style : neighbour;
        if (hasNl) return base == ScalarStyle.doubleQuoted ? ScalarStyle.doubleQuoted : ScalarStyle.literal;
        switch (base)
        {
        case ScalarStyle.singleQuoted: return ScalarStyle.singleQuoted;
        case ScalarStyle.doubleQuoted: return ScalarStyle.doubleQuoted;
        case ScalarStyle.plain:
            if (!plainSafe(value)) return ScalarStyle.singleQuoted;
            // a typed plain value (42, true) may be replaced by another typed one
            if (fromExisting && !existing.isNullLiteral && looksTyped(existing.value)) return ScalarStyle.plain;
            return looksTyped(value) ? ScalarStyle.singleQuoted : ScalarStyle.plain;
        default:
            return plainSafe(value) && !looksTyped(value) ? ScalarStyle.plain : ScalarStyle.singleQuoted;
        }
    }

    private static string fmtInline(string v, ScalarStyle st)
    {
        switch (st)
        {
        case ScalarStyle.plain: return v;
        case ScalarStyle.doubleQuoted: return escapeDouble(v);
        default: return "'" ~ v.replace("'", "''") ~ "'";
        }
    }

    private static string fmtKey(string k)
    {
        return plainSafe(k) && !looksTyped(k) ? k : (k.canFind('\n') ? escapeDouble(k) : "'" ~ k.replace("'", "''") ~ "'");
    }

    /**
    Style vote of an existing scalar: plain, or a quote style the author chose
    although plain would have been safe. Quotes forced by the content (`@x`,
    `yes`, `a: b`) say nothing about the file's style and do not vote.
    */
    private static bool styleVote(Node v, out ScalarStyle st)
    {
        if (v is null || v.kind != NodeKind.scalar || v.multiline) return false;
        if (v.style == ScalarStyle.plain) { if (v.isNullLiteral) return false; st = v.style; return true; }
        if (v.style != ScalarStyle.singleQuoted && v.style != ScalarStyle.doubleQuoted) return false;
        if (!plainSafe(v.value) || looksTyped(v.value)) return false;
        st = v.style;
        return true;
    }

    /**
    Style for a new scalar given candidate siblings ordered nearest first:
    the most common voting style; a tie goes to the nearest voting sibling.
    `preserve` when nobody votes.
    */
    private static ScalarStyle majorityStyle(Node[] nearestFirst)
    {
        size_t[3] count;
        ScalarStyle[] order;
        static size_t ix(ScalarStyle s)
        {
            return s == ScalarStyle.plain ? 0 : s == ScalarStyle.singleQuoted ? 1 : 2;
        }
        foreach (v; nearestFirst)
        {
            ScalarStyle st;
            if (!styleVote(v, st)) continue;
            if (count[ix(st)]++ == 0) order ~= st;
        }
        if (!order.length) return ScalarStyle.preserve;
        auto best = order[0];
        foreach (st; order[1 .. $]) if (count[ix(st)] > count[ix(best)]) best = st;
        return best;
    }

    private void collectScalars(Node n, ref Node[] acc, string key = null)
    {
        if (n is null) return;
        if (n.kind == NodeKind.scalar) { if (key is null) acc ~= n; return; }
        foreach (e; n.entries)
        {
            if (e.slot.value !is null && e.slot.value.kind == NodeKind.scalar)
            { if (key is null || e.key == key) acc ~= e.slot.value; }
            else collectScalars(e.slot.value, acc, key);
        }
        foreach (it; n.items) collectScalars(it.slot.value, acc, key);
    }

    /// Document-wide fallback: values under the same key anywhere, then any scalar, else preserve.
    private ScalarStyle documentStyle(string key)
    {
        Node[] acc;
        if (key !is null)
        {
            collectScalars(root_, acc, key);
            auto st = majorityStyle(acc);
            if (st != ScalarStyle.preserve) return st;
            acc = null;
        }
        collectScalars(root_, acc);
        return majorityStyle(acc);
    }

    /// Sibling style for a new scalar item (key null) or a new `key` in a mapping item, inserted at `pos` of `sq`.
    private ScalarStyle itemStyle(Node sq, size_t pos, string key)
    {
        Node[] same, others;
        if (sq !is null && sq.kind == NodeKind.sequence)
        {
            size_t[] idx;
            foreach (i; 0 .. sq.items.length) idx ~= i;
            import std.algorithm : sort;
            idx.sort!((a, b) => (a >= pos ? a - pos : pos - a - 1) < (b >= pos ? b - pos : pos - b - 1));
            foreach (i; idx)
            {
                auto v = sq.items[i].slot.value;
                if (v is null) continue;
                if (key is null) { if (v.kind == NodeKind.scalar) same ~= v; continue; }
                if (v.kind != NodeKind.mapping) continue;
                foreach (e; v.entries)
                    if (e.slot.value !is null && e.slot.value.kind == NodeKind.scalar)
                        (e.key == key ? same : others) ~= e.slot.value;
            }
        }
        auto st = majorityStyle(same);
        if (st == ScalarStyle.preserve) st = majorityStyle(others);
        if (st == ScalarStyle.preserve) st = documentStyle(key);
        return st;
    }

    /// Sibling style for a new key appended to mapping `m` (null: no siblings).
    private ScalarStyle mappingStyle(Node m, string key)
    {
        Node[] sib;
        if (m !is null && m.kind == NodeKind.mapping)
            foreach_reverse (e; m.entries)
                if (e.slot.value !is null && e.slot.value.kind == NodeKind.scalar) sib ~= e.slot.value;
        auto st = majorityStyle(sib);
        return st != ScalarStyle.preserve ? st : documentStyle(key);
    }

    private void createPath(Seg[] segs, Found f, string value, ScalarStyle style, bool emptyValue, bool raw = false)
    {
        auto rem = segs[f.depth .. $];
        foreach (sg; rem)
            if (sg.isIndex)
                throw new YamlEditException("cannot create sequence items through a path; use appendItem/insertItem");
        auto at = f.node;
        size_t indent, insertAt;
        if (f.depth == 0 && root_ is null)
        {
            indent = 0;
            insertAt = bodyEnd;
        }
        else if (at !is null && at.kind == NodeKind.mapping)
        {
            indent = at.indent;
            insertAt = at.last + 1;
        }
        else if (at is null && f.depth > 0)
        {
            if (f.container.kind == NodeKind.sequence)
                throw new YamlEditException("cannot add keys to an empty sequence item; use insertItem with a mapping");
            indent = f.container.indent + step;
            insertAt = f.slot.head + 1;
        }
        else if (at !is null && at.kind == NodeKind.opaque && at.emptyFlowMap && f.slot !is null)
        {
            auto head = lines[f.slot.head].text;
            setLine(f.slot.head, head[0 .. at.col0].stripRight ~ head[at.col1 .. $]);
            createPath(segs, walk(segs), value, style, emptyValue, raw);
            return;
        }
        else
        {
            string where = f.depth ? text(" (line ", at is null ? 0 : at.first + 1, ")") : "";
            string what = at is null ? "a null value" : at.kind == NodeKind.opaque
                ? "an unsupported " ~ at.opaqueReason ~ " (preserved as opaque)" : "a " ~ kindName(at.kind);
            throw new YamlEditException(text("cannot create '", rem[0].key, "': parent is ", what, where));
        }
        string[] out_;
        size_t ind = indent;
        foreach (i, sg; rem)
        {
            string k = pad(ind) ~ fmtKey(sg.key) ~ ":";
            if (i + 1 < rem.length) { out_ ~= k; ind += step; continue; }
            if (emptyValue) { out_ ~= k; break; }
            if (raw) { out_ ~= k ~ " " ~ value; break; }
            auto st = resolveStyle(value, style, null, mappingStyle(i == 0 ? at : null, sg.key));
            if (st == ScalarStyle.literal)
            {
                auto b = blockLiteral(value, ind + step, ind);
                out_ ~= k ~ " " ~ b.header;
                out_ ~= b.lines;
            }
            else
                out_ ~= k ~ " " ~ fmtInline(value, st);
        }
        replaceLines(insertAt, insertAt, out_);
    }

    private struct ItemVal
    {
        bool isMap;
        string scalar;
        string[2][] pairs;
    }

    private static size_t itemEnd(Item it)
    {
        auto v = it.slot.value;
        return v !is null && v.last > it.slot.head ? v.last : it.slot.head;
    }

    private void guardOwnLine(Item it)
    {
        auto s = lines[it.slot.head].text;
        foreach (ch; s[0 .. it.dashCol])
            if (ch != ' ')
                throw err("editing a sequence that starts on its parent's line ('- - x') is not supported",
                    it.slot.head);
    }

    private size_t itemGap(Item it)
    {
        auto s = lines[it.slot.head].text;
        auto c2 = skipWs(s, it.dashCol + 1);
        if (c2 < s.length && s[c2] != '#') return c2 - it.dashCol - 1;
        return 1;
    }

    private string commentGap(Item it)
    {
        if (it is null) return "  ";
        auto s = lines[it.slot.head].text;
        auto tc = findComment(s, it.slot.after);
        if (tc >= s.length) return "  ";
        return s[tc .. s.indexOf('#', tc)];
    }

    private void insertItemImpl(string path, long index, ItemVal iv, string comment)
    {
        if (iv.isMap && iv.pairs.length == 0) throw new YamlEditException("mapping item needs at least one key");
        if (comment.canFind('\n')) throw new YamlEditException("comments must be a single line");
        auto segs = parsePath(path);
        auto f = walk(segs);
        if (!f.ok)
        {
            if (segs.length && segs[$ - 1].isIndex) throw notFound(path, f);
            createPath(segs, f, null, ScalarStyle.preserve, true);
            f = walk(segs);
        }
        auto sq = f.node;
        if (sq !is null && sq.kind == NodeKind.opaque && sq.emptyFlowSeq && f.slot !is null)
        {
            auto head = lines[f.slot.head].text;
            setLine(f.slot.head, head[0 .. sq.col0].stripRight ~ head[sq.col1 .. $]);
            f = walk(segs);
            sq = f.node;
        }
        size_t dashCol, gap = 1, insertAt;
        Item nb;
        if (sq is null)
        {
            if (segs.length == 0) { dashCol = 0; insertAt = bodyEnd; }
            else
            {
                if (f.container.kind == NodeKind.sequence)
                    throw new YamlEditException(path ~ ": cannot add a nested sequence to an empty item");
                dashCol = f.container.indent + cast(size_t)(seqOffset >= 0 ? seqOffset : step);
                insertAt = f.slot.head + 1;
            }
        }
        else if (sq.kind != NodeKind.sequence)
            throw new YamlEditException(text(path, " is ", aKind(sq), ", not a block sequence",
                sq.kind == NodeKind.scalar ? "; call toSequence() first" : ""), sq.first + 1);
        else
        {
            auto n = sq.items.length;
            if (index < 0 || index >= cast(long) n)
            {
                nb = sq.items[$ - 1];
                insertAt = itemEnd(nb) + 1;
            }
            else
            {
                nb = sq.items[cast(size_t) index];
                long boundary = index > 0 ? cast(long) itemEnd(sq.items[cast(size_t) index - 1])
                    : (f.slot !is null ? cast(long) f.slot.head : cast(long) bodyStart - 1);
                size_t k = nb.slot.head;
                while (cast(long) k - 1 > boundary && lines[k - 1].text.stripLeft.startsWith("#")) k--;
                insertAt = k;
            }
            guardOwnLine(nb);
            dashCol = nb.dashCol;
            gap = itemGap(nb);
        }
        size_t pos = sq is null || sq.kind != NodeKind.sequence ? 0
            : (index < 0 || index >= cast(long) sq.items.length ? sq.items.length : cast(size_t) index);
        replaceLines(insertAt, insertAt, renderItem(dashCol, gap, iv, comment, nb, sq, pos));
    }

    private string[] renderItem(size_t dashCol, size_t gap, ItemVal iv, string comment, Item nb, Node sq, size_t pos)
    {
        string pre = pad(dashCol) ~ "-" ~ pad(gap);
        size_t contentCol = dashCol + 1 + gap;
        string cmt = comment.length ? commentGap(nb) ~ "# " ~ comment : "";
        string[] out_;
        if (!iv.isMap)
        {
            auto st = resolveStyle(iv.scalar, ScalarStyle.preserve, null, itemStyle(sq, pos, null));
            if (st == ScalarStyle.literal)
            {
                auto b = blockLiteral(iv.scalar, contentCol, dashCol);
                return [pre ~ b.header ~ cmt] ~ b.lines;
            }
            return [pre ~ fmtInline(iv.scalar, st) ~ cmt];
        }
        foreach (i, kv; iv.pairs)
        {
            string lead = i == 0 ? pre : pad(contentCol);
            string c = i == 0 ? cmt : "";
            auto st = resolveStyle(kv[1], ScalarStyle.preserve, null, itemStyle(sq, pos, kv[0]));
            string ln = lead ~ fmtKey(kv[0]) ~ ":";
            if (st == ScalarStyle.literal)
            {
                auto b = blockLiteral(kv[1], contentCol + step, contentCol);
                out_ ~= ln ~ " " ~ b.header ~ c;
                out_ ~= b.lines;
            }
            else
                out_ ~= ln ~ " " ~ fmtInline(kv[1], st) ~ c;
        }
        return out_;
    }

    private void removeItemAt(Seg[] seqSegs, long index)
    {
        auto f = walk(seqSegs);
        if (!f.ok || f.node is null || f.node.kind != NodeKind.sequence)
            throw new YamlEditException("not a block sequence");
        auto sq = f.node;
        long ix = index < 0 ? cast(long) sq.items.length + index : index;
        if (ix < 0 || ix >= cast(long) sq.items.length) throw new YamlEditException(text("no item ", index));
        auto it = sq.items[cast(size_t) ix];
        guardOwnLine(it);
        if (sq.items.length == 1 && f.slot !is null)
        {
            writeSlot(f.slot, f.container.indent, "[]", ScalarStyle.plain, true);
            return;
        }
        replaceLines(it.slot.head, itemEnd(it) + 1, null);
    }

    private void removeEntry(Found f)
    {
        auto m = f.container;
        Entry e;
        size_t idx;
        foreach (i, x; m.entries) if (&x.slot is f.slot) { e = x; idx = i; }
        size_t endE = e.slot.value !is null && e.slot.value.last > e.slot.head ? e.slot.value.last : e.slot.head;
        auto s = lines[e.slot.head].text;
        bool ownLine = true;
        foreach (ch; s[0 .. e.keyCol]) if (ch != ' ') ownLine = false;
        if (ownLine)
        {
            replaceLines(e.slot.head, endE + 1, null);
            return;
        }
        // first key of a compact mapping in a sequence item: "- a: 1"
        if (m.entries.length == 1)
            throw new YamlEditException("removing the only key of a sequence item; remove the item instead",
                e.slot.head + 1);
        auto nx = m.entries[1];
        auto nxLine = lines[nx.slot.head].text;
        replaceLines(e.slot.head, nx.slot.head + 1, [s[0 .. e.keyCol] ~ nxLine[nx.keyCol .. $]]);
    }
}

// ---------------------------------------------------------------------------
// escapes
// ---------------------------------------------------------------------------

/**
Format `v` as an inline scalar that reads back as the same string: plain
when that is safe and cannot resolve to another type, else quoted.
*/
string quoteScalar(string v)
{
    return Document.fmtInline(v, Document.resolveStyle(v, ScalarStyle.preserve, null, ScalarStyle.preserve) == ScalarStyle.literal
        ? ScalarStyle.doubleQuoted : Document.resolveStyle(v, ScalarStyle.preserve, null, ScalarStyle.preserve));
}

private string unescapeDouble(string raw, size_t li)
{
    auto a = appender!string;
    for (size_t i = 0; i < raw.length; i++)
    {
        char ch = raw[i];
        if (ch != '\\') { a.put(ch); continue; }
        if (++i >= raw.length) throw new YamlEditException("dangling escape in double-quoted scalar", li + 1);
        char e = raw[i];
        size_t hex;
        switch (e)
        {
        case '0': a.put('\0'); break;
        case 'a': a.put('\a'); break;
        case 'b': a.put('\b'); break;
        case 't': case '\t': a.put('\t'); break;
        case 'n': a.put('\n'); break;
        case 'v': a.put('\v'); break;
        case 'f': a.put('\f'); break;
        case 'r': a.put('\r'); break;
        case 'e': a.put('\x1b'); break;
        case ' ': a.put(' '); break;
        case '"': a.put('"'); break;
        case '/': a.put('/'); break;
        case '\\': a.put('\\'); break;
        case 'N': a.put(cast(dchar) 0x85); break;
        case '_': a.put(cast(dchar) 0xA0); break;
        case 'L': a.put(cast(dchar) 0x2028); break;
        case 'P': a.put(cast(dchar) 0x2029); break;
        case 'x': hex = 2; break;
        case 'u': hex = 4; break;
        case 'U': hex = 8; break;
        default:
            throw new YamlEditException(text("unknown escape '\\", e, "'"), li + 1);
        }
        if (hex)
        {
            if (i + hex >= raw.length + 0 && i + hex > raw.length - 1 + 1)
                throw new YamlEditException("short hex escape", li + 1);
            uint cp;
            try cp = to!uint(raw[i + 1 .. i + 1 + hex], 16);
            catch (Exception) throw new YamlEditException("bad hex escape", li + 1);
            a.put(cast(dchar) cp);
            i += hex;
        }
    }
    return a.data;
}

private string escapeDouble(string v)
{
    import std.format : format;
    auto a = appender!string;
    a.put('"');
    foreach (dchar ch; v)
    {
        switch (ch)
        {
        case '"': a.put(`\"`); break;
        case '\\': a.put(`\\`); break;
        case '\n': a.put(`\n`); break;
        case '\t': a.put(`\t`); break;
        case '\r': a.put(`\r`); break;
        default:
            if (ch < 0x20 || ch == 0x7f) a.put(format(`\x%02X`, cast(uint) ch));
            else a.put(ch);
        }
    }
    a.put('"');
    return a.data;
}

unittest
{
    enum src = "# c\na: 1  # one\nb:\n  - x\n";
    auto d = Document.parse(src);
    assert(d.emit() == src);
    assert(d.get("a") == "1");
    assert(d.get("b[0]") == "x");
    d.set("a", "2");
    assert(d.emit() == "# c\na: 2  # one\nb:\n  - x\n");
}
