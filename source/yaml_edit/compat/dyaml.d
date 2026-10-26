/**
D-YAML compatible facade over yaml_edit.

Existing D-YAML code switches by changing one import:
---
// import dyaml;
import yaml_edit.compat.dyaml;
---
`Loader`, `Node`, `Node.Pair`, `NodeID`, `NodeType`, `YAMLNull`, `dumper`
and the exception names behave like D-YAML 0.10. The difference is the
dump: a node tree loaded from text is written back with its comments,
quoting, indentation and key order kept, and only the changed lines differ.

This module only translates names. The editing work is done by
`yaml_edit.Document`, which a loaded root exposes via `document`.
*/
module yaml_edit.compat.dyaml;

import std.algorithm : canFind, map, startsWith;
import std.array : appender, array, replace;
import std.conv : ConvException, to;
import std.datetime.systime : SysTime;
import std.exception : enforce;
import std.math : isInfinity, isNaN;
import std.range : isOutputRange, put;
import std.regex : ctRegex, matchFirst;
import std.string : indexOf, toLower;
import std.traits : isFloatingPoint, isIntegral, isSomeString, Unqual;

import yaml_edit;

// ------------------------------------------------------------------ exceptions

/// Base class of everything thrown by this module (D-YAML name).
class YAMLException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Wrong node type, missing key or index (D-YAML name).
class NodeException : YAMLException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Input that cannot be loaded (D-YAML name).
class LoaderException : YAMLException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Unrepresentable value at dump time.
class RepresenterException : YAMLException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

// ----------------------------------------------------------------------- types

/// Null value type (D-YAML name).
struct YAMLNull
{
    string toString() const @safe pure nothrow { return "null"; }
}

/// Node shape (D-YAML name).
enum NodeID : ubyte
{
    scalar,
    sequence,
    mapping,
    invalid
}

/// Resolved value type (D-YAML name and order).
enum NodeType
{
    null_,
    merge,
    boolean,
    integer,
    decimal,
    binary,
    timestamp,
    string,
    mapping,
    sequence,
    invalid
}

/// Position of a node in its source; line and column are 0-based like D-YAML.
struct Mark
{
    string name;
    uint line;
    uint column;
}

private final class Origin
{
    Document doc;
    Node snapshot; // deep copy of the tree as it was last written
}

private enum tagNull = "tag:yaml.org,2002:null";
private enum tagBool = "tag:yaml.org,2002:bool";
private enum tagInt = "tag:yaml.org,2002:int";
private enum tagFloat = "tag:yaml.org,2002:float";
private enum tagStr = "tag:yaml.org,2002:str";
private enum tagTime = "tag:yaml.org,2002:timestamp";
private enum tagSeq = "tag:yaml.org,2002:seq";
private enum tagMap = "tag:yaml.org,2002:map";

/// YAML node: a scalar, sequence or mapping (D-YAML compatible).
struct Node
{
    /// Key/value pair of a mapping (D-YAML name).
    static struct Pair
    {
        Node key;
        Node value;

        this(K, V)(K key, V value)
        {
            static if (is(Unqual!K == Node)) this.key = key; else this.key = Node(key);
            static if (is(Unqual!V == Node)) this.value = value; else this.value = Node(value);
        }

        bool opEquals(const ref Pair rhs) const
        {
            return nodeEq(key, rhs.key) && nodeEq(value, rhs.value);
        }
    }

    package
    {
        NodeType type_ = NodeType.invalid;
        string tag_;
        string str_;  // string value, or source text of other scalars
        bool bool_;
        long long_;
        real real_ = 0;
        Node[] seq_;
        Pair[] map_;
        Origin origin_;
        Mark mark_;
    }

    /// Construct a scalar or collection from a D value (D-YAML constructor).
    this(T)(T value, string tag = null)
        if (!is(Unqual!T == Node))
    {
        alias U = Unqual!T;
        static if (is(U == YAMLNull) || is(U == typeof(null)))
        {
            type_ = NodeType.null_;
            tag_ = tagNull;
        }
        else static if (is(U == bool))
        {
            type_ = NodeType.boolean;
            bool_ = value;
            tag_ = tagBool;
        }
        else static if (isIntegral!U)
        {
            type_ = NodeType.integer;
            long_ = cast(long) value;
            tag_ = tagInt;
        }
        else static if (isFloatingPoint!U)
        {
            type_ = NodeType.decimal;
            real_ = value;
            tag_ = tagFloat;
        }
        else static if (isSomeString!U)
        {
            type_ = NodeType.string;
            str_ = to!string(value);
            tag_ = tagStr;
        }
        else static if (is(U == SysTime))
        {
            type_ = NodeType.timestamp;
            str_ = value.toISOExtString();
            tag_ = tagTime;
        }
        else static if (is(U == Pair[]) || is(U : const(Pair)[]))
        {
            type_ = NodeType.mapping;
            map_ = cast(Pair[]) value.dup;
            tag_ = tagMap;
        }
        else static if (is(U : const(Node)[]))
        {
            type_ = NodeType.sequence;
            seq_ = cast(Node[]) value.dup;
            tag_ = tagSeq;
        }
        else static if (is(U == V[K], K, V))
        {
            type_ = NodeType.mapping;
            tag_ = tagMap;
            foreach (k, v; value) map_ ~= Pair(k, v);
        }
        else static if (is(U == E[], E))
        {
            type_ = NodeType.sequence;
            tag_ = tagSeq;
            foreach (e; value) seq_ ~= Node(e);
        }
        else
            static assert(false, "cannot construct a Node from " ~ T.stringof);
        if (tag !is null) tag_ = tag;
    }

    /// Mapping from parallel key and value arrays (D-YAML constructor).
    this(K, V)(K[] keys, V[] values, string tag = null)
        if (!isSomeString!(K[]) && !isSomeString!(V[]))
    {
        enforce(keys.length == values.length,
            new NodeException("keys and values must have the same length"));
        type_ = NodeType.mapping;
        tag_ = tag is null ? tagMap : tag;
        foreach (i, k; keys) map_ ~= Pair(k, values[i]);
    }

    // ------------------------------------------------------------- inspection

    /// Shape of the node.
    NodeID nodeID() const @safe pure nothrow
    {
        switch (type_)
        {
        case NodeType.invalid: return NodeID.invalid;
        case NodeType.mapping: return NodeID.mapping;
        case NodeType.sequence: return NodeID.sequence;
        default: return NodeID.scalar;
        }
    }

    /// Resolved type.
    NodeType type() const @safe pure nothrow { return type_; }

    /// Resolved tag, e.g. `tag:yaml.org,2002:str`.
    string tag() const @safe pure nothrow { return tag_; }

    /// False for a default-constructed node.
    bool isValid() const @safe pure nothrow { return type_ != NodeType.invalid; }

    /// Where the node starts in its source (0-based, D-YAML convention).
    Mark startMark() const @safe pure nothrow { return mark_; }

    /// Number of items or pairs; throws for scalars.
    size_t length() const
    {
        if (type_ == NodeType.sequence) return seq_.length;
        if (type_ == NodeType.mapping) return map_.length;
        throw new NodeException("trying to get the length of a " ~ typeName ~ " node");
    }

    private string typeName() const @safe pure nothrow
    {
        switch (type_)
        {
        case NodeType.null_: return "null";
        case NodeType.boolean: return "bool";
        case NodeType.integer: return "integer";
        case NodeType.decimal: return "decimal";
        case NodeType.timestamp: return "timestamp";
        case NodeType.string: return "string";
        case NodeType.mapping: return "mapping";
        case NodeType.sequence: return "sequence";
        default: return "invalid";
        }
    }

    /// Format-preserving editor behind a loaded root, or null.
    Document document() { return origin_ is null ? null : origin_.doc; }

    // ------------------------------------------------------------- conversion

    /// True when `as!T` would succeed.
    bool convertsTo(T)() const
    {
        try { cast(void) (cast() this).as!T; return true; }
        catch (Exception) return false;
    }

    /// Value as `T` (D-YAML `as` / `get`).
    T as(T)() const
    {
        alias U = Unqual!T;
        static if (is(U == Node)) return cast(T) this;
        else static if (is(U == YAMLNull))
        {
            if (type_ == NodeType.null_) return YAMLNull();
        }
        else static if (is(U == bool))
        {
            if (type_ == NodeType.boolean) return bool_;
        }
        else static if (isIntegral!U)
        {
            if (type_ == NodeType.integer)
            {
                if (long_ < U.min || long_ > U.max)
                    throw new NodeException("integer " ~ to!string(long_) ~ " does not fit in " ~ U.stringof);
                return cast(U) long_;
            }
        }
        else static if (isFloatingPoint!U)
        {
            if (type_ == NodeType.decimal) return cast(U) real_;
            if (type_ == NodeType.integer) return cast(U) long_;
        }
        else static if (isSomeString!U)
        {
            switch (type_)
            {
            case NodeType.string:
            case NodeType.timestamp: return to!U(str_);
            case NodeType.boolean: return to!U(bool_ ? "true" : "false");
            case NodeType.integer: return to!U(long_);
            case NodeType.decimal: return to!U(real_);
            default: break;
            }
        }
        else static if (is(U == SysTime))
        {
            if (type_ == NodeType.timestamp) return parseTimestamp(str_);
        }
        else static if (is(U == E[], E))
        {
            if (type_ == NodeType.sequence)
            {
                U r;
                foreach (ref n; seq_) r ~= n.as!E;
                return r;
            }
        }
        else
            static assert(false, "cannot convert a Node to " ~ T.stringof);
        throw new NodeException("cannot convert a " ~ typeName ~ " node to " ~ T.stringof);
    }

    /// Alias of `as` (D-YAML name).
    alias get = as;

    // ----------------------------------------------------------------- access

    /// Item of a sequence (integral index) or value of a mapping (any key).
    ref Node opIndex(T)(T index)
    {
        if (type_ == NodeType.sequence)
        {
            static if (isIntegral!T)
            {
                if (index >= 0 && cast(size_t) index < seq_.length) return seq_[cast(size_t) index];
                throw new NodeException("sequence index out of range: " ~ to!string(index));
            }
            else
                throw new NodeException("only integers can index a sequence");
        }
        if (type_ == NodeType.mapping)
        {
            auto k = keyNode(index);
            foreach (ref p; map_) if (nodeEq(p.key, k)) return p.value;
            throw new NodeException("mapping index not found: " ~ to!string(index));
        }
        throw new NodeException("trying to index a " ~ typeName ~ " node");
    }

    /// Set an item (sequence) or key (mapping, added when missing).
    void opIndexAssign(V, K)(V value, K index)
    {
        Node v = toNode(value);
        if (type_ == NodeType.sequence)
        {
            static if (isIntegral!K)
            {
                if (index >= 0 && cast(size_t) index < seq_.length) { seq_[cast(size_t) index] = v; return; }
                throw new NodeException("sequence index out of range: " ~ to!string(index));
            }
            else
                throw new NodeException("only integers can index a sequence");
        }
        if (type_ == NodeType.mapping)
        {
            auto k = keyNode(index);
            foreach (ref p; map_) if (nodeEq(p.key, k)) { p.value = v; return; }
            map_ ~= Pair(k, v);
            return;
        }
        throw new NodeException("trying to index a " ~ typeName ~ " node");
    }

    /// True when a mapping has `key`.
    bool containsKey(K)(K key) const
    {
        if (type_ != NodeType.mapping)
            throw new NodeException("trying to use containsKey on a " ~ typeName ~ " node");
        auto k = keyNode(key);
        foreach (ref p; map_) if (nodeEq(p.key, k)) return true;
        return false;
    }

    /// True when a sequence holds `value`, or a mapping has it as a value.
    bool contains(V)(V value) const
    {
        auto v = toNode(value);
        if (type_ == NodeType.sequence)
        {
            foreach (ref n; seq_) if (nodeEq(n, v)) return true;
            return false;
        }
        if (type_ == NodeType.mapping)
        {
            foreach (ref p; map_) if (nodeEq(p.value, v)) return true;
            return false;
        }
        throw new NodeException("trying to use contains on a " ~ typeName ~ " node");
    }

    /// Append to a sequence.
    void add(V)(V value)
    {
        if (type_ != NodeType.sequence)
            throw new NodeException("trying to add an item to a " ~ typeName ~ " node");
        seq_ ~= toNode(value);
    }

    /// Append a pair to a mapping (no duplicate check, as in D-YAML).
    void add(K, V)(K key, V value)
    {
        if (type_ != NodeType.mapping)
            throw new NodeException("trying to add a pair to a " ~ typeName ~ " node");
        map_ ~= Pair(keyNode(key), toNode(value));
    }

    /// Remove the first item equal to `value` (sequence) or the first pair with that value (mapping).
    void remove(V)(V value)
    {
        auto v = toNode(value);
        if (type_ == NodeType.sequence)
        {
            foreach (i, ref n; seq_) if (nodeEq(n, v)) { seq_ = seq_[0 .. i] ~ seq_[i + 1 .. $]; return; }
            return;
        }
        if (type_ == NodeType.mapping)
        {
            foreach (i, ref p; map_) if (nodeEq(p.value, v)) { map_ = map_[0 .. i] ~ map_[i + 1 .. $]; return; }
            return;
        }
        throw new NodeException("trying to remove from a " ~ typeName ~ " node");
    }

    /// Remove item `index` (sequence) or the pair with key `index` (mapping).
    void removeAt(K)(K index)
    {
        if (type_ == NodeType.sequence)
        {
            static if (isIntegral!K)
            {
                if (index >= 0 && cast(size_t) index < seq_.length)
                    seq_ = seq_[0 .. cast(size_t) index] ~ seq_[cast(size_t) index + 1 .. $];
                return;
            }
            else
                throw new NodeException("only integers can index a sequence");
        }
        if (type_ == NodeType.mapping)
        {
            auto k = keyNode(index);
            foreach (i, ref p; map_) if (nodeEq(p.key, k)) { map_ = map_[0 .. i] ~ map_[i + 1 .. $]; return; }
            return;
        }
        throw new NodeException("trying to remove from a " ~ typeName ~ " node");
    }

    /// Items of a sequence converted to `T`.
    T[] sequence(T = Node)() const
    {
        if (type_ != NodeType.sequence)
            throw new NodeException("trying to read a " ~ typeName ~ " node as a sequence");
        return seq_.map!(n => n.as!T).array;
    }

    /// Pairs of a mapping.
    Pair[] mapping() const
    {
        if (type_ != NodeType.mapping)
            throw new NodeException("trying to read a " ~ typeName ~ " node as a mapping");
        return cast(Pair[]) map_;
    }

    /// Keys of a mapping converted to `K`.
    K[] mappingKeys(K = Node)() const
    {
        return mapping().map!(p => p.key.as!K).array;
    }

    /// Values of a mapping converted to `V`.
    V[] mappingValues(V = Node)() const
    {
        return mapping().map!(p => p.value.as!V).array;
    }

    /// `foreach (ref Node item; seq)`.
    int opApply(scope int delegate(ref Node) dg)
    {
        if (type_ != NodeType.sequence)
            throw new NodeException("trying to foreach over a " ~ typeName ~ " node as a sequence");
        foreach (ref n; seq_) if (auto r = dg(n)) return r;
        return 0;
    }

    /// `foreach (ref Node key, ref Node value; map)`.
    int opApply(scope int delegate(ref Node, ref Node) dg)
    {
        if (type_ != NodeType.mapping)
            throw new NodeException("trying to foreach over a " ~ typeName ~ " node as a mapping");
        foreach (ref p; map_) if (auto r = dg(p.key, p.value)) return r;
        return 0;
    }

    /// `foreach (string key, ref Node value; map)`.
    int opApply(scope int delegate(string, ref Node) dg)
    {
        if (type_ != NodeType.mapping)
            throw new NodeException("trying to foreach over a " ~ typeName ~ " node as a mapping");
        foreach (ref p; map_) if (auto r = dg(p.key.as!string, p.value)) return r;
        return 0;
    }

    bool opEquals(const ref Node rhs) const { return nodeEq(this, rhs); }

    bool opEquals(T)(T rhs) const if (!is(Unqual!T == Node))
    {
        try { auto r = Node(rhs); return nodeEq(this, r); }
        catch (Exception) return false;
    }

    size_t toHash() const nothrow @trusted
    {
        try return hashOf(type_) ^ hashOf(str_) ^ hashOf(long_) ^ hashOf(seq_.length) ^ hashOf(map_.length);
        catch (Exception) return 0;
    }

    string toString() const
    {
        switch (type_)
        {
        case NodeType.mapping:
        case NodeType.sequence: return renderFlow(this);
        case NodeType.null_: return "null";
        case NodeType.invalid: return "<invalid>";
        default: return as!string;
        }
    }

    private static Node keyNode(T)(T k)
    {
        static if (is(Unqual!T == Node)) return k; else return Node(k);
    }

    private static Node toNode(T)(T v)
    {
        static if (is(Unqual!T == Node)) return v; else return Node(v);
    }
}

private bool nodeEq(const ref Node a, const ref Node b)
{
    if (a.type_ != b.type_) return false;
    final switch (a.type_)
    {
    case NodeType.invalid:
    case NodeType.null_:
    case NodeType.merge:
        return true;
    case NodeType.boolean: return a.bool_ == b.bool_;
    case NodeType.integer: return a.long_ == b.long_;
    case NodeType.decimal:
        return a.real_ == b.real_ || (isNaN(a.real_) && isNaN(b.real_));
    case NodeType.binary:
    case NodeType.timestamp:
    case NodeType.string:
        return a.str_ == b.str_;
    case NodeType.sequence:
        if (a.seq_.length != b.seq_.length) return false;
        foreach (i; 0 .. a.seq_.length) if (!nodeEq(a.seq_[i], b.seq_[i])) return false;
        return true;
    case NodeType.mapping:
        if (a.map_.length != b.map_.length) return false;
        foreach (i; 0 .. a.map_.length)
            if (!nodeEq(a.map_[i].key, b.map_[i].key) || !nodeEq(a.map_[i].value, b.map_[i].value))
                return false;
        return true;
    }
}

private Node deepCopy(const ref Node n)
{
    Node r;
    r.type_ = n.type_;
    r.tag_ = n.tag_;
    r.str_ = n.str_;
    r.bool_ = n.bool_;
    r.long_ = n.long_;
    r.real_ = n.real_;
    r.mark_ = n.mark_;
    foreach (ref c; n.seq_) r.seq_ ~= deepCopy(c);
    foreach (ref p; n.map_)
    {
        Node.Pair q;
        q.key = deepCopy(p.key);
        q.value = deepCopy(p.value);
        r.map_ ~= q;
    }
    return r;
}

private SysTime parseTimestamp(string s)
{
    import core.time : hnsecs, hours, minutes;
    import std.datetime.date : DateTime;
    import std.datetime.timezone : SimpleTimeZone, UTC;
    enum re = ctRegex!(`^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})(?:(?:[Tt]|[ \t]+)([0-9]{1,2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]*))?(?:[ \t]*(Z|([-+])([0-9]{1,2})(?::([0-9]{2}))?))?)?$`);
    auto m = matchFirst(s, re);
    if (m.empty) throw new NodeException("invalid timestamp: " ~ s);
    try
    {
        auto dt = DateTime(to!int(m[1]), to!int(m[2]), to!int(m[3]),
            m[4].length ? to!int(m[4]) : 0, m[5].length ? to!int(m[5]) : 0, m[6].length ? to!int(m[6]) : 0);
        long frac = 0;
        if (m[7].length)
        {
            auto f = m[7].length > 7 ? m[7][0 .. 7] : m[7];
            frac = to!long(f);
            foreach (_; f.length .. 7) frac *= 10;
        }
        if (!m[4].length || !m[8].length || m[8] == "Z") return SysTime(dt, hnsecs(frac), UTC());
        auto off = hours(to!int(m[10])) + minutes(m[11].length ? to!int(m[11]) : 0);
        if (m[9] == "-") off = -off;
        return SysTime(dt, hnsecs(frac), new immutable SimpleTimeZone(off));
    }
    catch (Exception e)
        throw new NodeException("invalid timestamp: " ~ s);
}

// ------------------------------------------------------------------- resolver

/// Resolve a plain scalar the way D-YAML 0.10 does (YAML 1.1 core types).
private Node resolvePlain(string v)
{
    enum reBool = ctRegex!(`^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$`);
    enum reFloat = ctRegex!(`^(?:[-+]?([0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|[-+]?(?:[0-9][0-9_]*)?\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$`);
    enum reInt = ctRegex!(`^(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)$`);
    enum reNull = ctRegex!(`^$|^(?:~|null|Null|NULL)$`);
    enum reTime = ctRegex!(`^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$|^[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?$`);
    Node n;
    n.str_ = v;
    if (!matchFirst(v, reBool).empty)
    {
        n.type_ = NodeType.boolean;
        n.tag_ = tagBool;
        auto l = v.toLower;
        n.bool_ = l == "yes" || l == "true" || l == "on";
    }
    else if (!matchFirst(v, reFloat).empty)
    {
        n.type_ = NodeType.decimal;
        n.tag_ = tagFloat;
        n.real_ = parseReal(v);
    }
    else if (!matchFirst(v, reInt).empty)
    {
        n.type_ = NodeType.integer;
        n.tag_ = tagInt;
        n.long_ = parseLong(v);
    }
    else if (!matchFirst(v, reNull).empty)
    {
        n.type_ = NodeType.null_;
        n.tag_ = tagNull;
    }
    else if (!matchFirst(v, reTime).empty)
    {
        n.type_ = NodeType.timestamp;
        n.tag_ = tagTime;
    }
    else
    {
        n.type_ = NodeType.string;
        n.tag_ = tagStr;
    }
    return n;
}

private long parseLong(string s)
{
    string v = s.replace("_", "");
    long sign = 1;
    if (v[0] == '-' || v[0] == '+') { if (v[0] == '-') sign = -1; v = v[1 .. $]; }
    try
    {
        if (v == "0") return 0;
        if (v.startsWith("0b")) return sign * to!long(v[2 .. $], 2);
        if (v.startsWith("0x")) return sign * to!long(v[2 .. $], 16);
        if (v[0] == '0') return sign * to!long(v, 8);
        if (v.canFind(':'))
        {
            long r = 0;
            foreach (d; v.splitColon) r = r * 60 + to!long(d);
            return sign * r;
        }
        return sign * to!long(v);
    }
    catch (ConvException)
        throw new LoaderException("integer out of range: " ~ s);
}

private real parseReal(string s)
{
    string v = s.replace("_", "").toLower;
    real sign = 1;
    if (v[0] == '-' || v[0] == '+') { if (v[0] == '-') sign = -1; v = v[1 .. $]; }
    if (v == ".inf") return sign * real.infinity;
    if (v == ".nan") return real.nan;
    if (v.canFind(':'))
    {
        real r = 0;
        foreach (d; v.splitColon) r = r * 60 + to!real(d);
        return sign * r;
    }
    if (v.startsWith(".")) v = "0" ~ v;
    if (v.endsWith(".")) v ~= "0";
    return sign * to!real(v);
}

private string[] splitColon(string v)
{
    import std.array : split;
    return v.split(":");
}

private bool endsWith(string s, string t) { return s.length >= t.length && s[$ - t.length .. $] == t; }

// --------------------------------------------------------------------- loader

private Node fromRef(Document doc, NodeRef r, string name)
{
    Node n;
    n.mark_ = Mark(name, r.line ? cast(uint)(r.line - 1) : 0, 0);
    final switch (r.kind)
    {
    case NodeKind.null_:
        n.type_ = NodeType.null_;
        n.tag_ = tagNull;
        break;
    case NodeKind.scalar:
        if (r.style == ScalarStyle.plain)
        {
            auto m = n.mark_;
            n = resolvePlain(r.value);
            n.mark_ = m;
        }
        else
        {
            n.type_ = NodeType.string;
            n.tag_ = tagStr;
            n.str_ = r.value;
        }
        break;
    case NodeKind.mapping:
        n.type_ = NodeType.mapping;
        n.tag_ = tagMap;
        auto styles = r.keyStyles;
        foreach (i, k; r.keys)
        {
            Node key = styles[i] == ScalarStyle.plain ? resolvePlain(k) : Node(k);
            n.map_ ~= Node.Pair(key, fromRef(doc, r[k], name));
        }
        break;
    case NodeKind.sequence:
        n.type_ = NodeType.sequence;
        n.tag_ = tagSeq;
        foreach (i; 0 .. r.length) n.seq_ ~= fromRef(doc, r[i], name);
        break;
    case NodeKind.opaque:
        if (r.opaqueReason != "flow collection")
            throw new LoaderException(name ~ ":" ~ to!string(r.line) ~ ": " ~ r.opaqueReason
                ~ " is not supported by yaml_edit.compat.dyaml (yaml_edit keeps it opaque)");
        auto src = doc.source(r);
        size_t i = 0;
        auto m = n.mark_;
        n = FlowParser(src, name, r.line).parse(i);
        n.mark_ = m;
        break;
    }
    return n;
}

/// Read-only parser for flow collections inside an otherwise block document.
private struct FlowParser
{
    string s;
    string name;
    size_t line;

    LoaderException fail(string m) { return new LoaderException(name ~ ":" ~ to!string(line) ~ ": flow collection: " ~ m); }

    void ws(ref size_t i)
    {
        while (i < s.length)
        {
            char c = s[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') i++;
            else if (c == '#') { while (i < s.length && s[i] != '\n') i++; }
            else break;
        }
    }

    Node parse(ref size_t i)
    {
        ws(i);
        if (i >= s.length) throw fail("unexpected end");
        char c = s[i];
        if (c == '[')
        {
            i++;
            Node n = Node(cast(Node[]) []);
            for (;;)
            {
                ws(i);
                if (i < s.length && s[i] == ']') { i++; return n; }
                auto item = parse(i);
                ws(i);
                if (i < s.length && s[i] == ':' )
                {
                    i++;
                    auto v = parse(i);
                    item = Node([Node.Pair(item, v)]);
                    ws(i);
                }
                n.seq_ ~= item;
                if (i < s.length && s[i] == ',') { i++; continue; }
                if (i < s.length && s[i] == ']') { i++; return n; }
                throw fail("expected ',' or ']'");
            }
        }
        if (c == '{')
        {
            i++;
            Node n = Node(cast(Node.Pair[]) []);
            for (;;)
            {
                ws(i);
                if (i < s.length && s[i] == '}') { i++; return n; }
                auto k = parse(i);
                ws(i);
                Node v = Node(YAMLNull());
                if (i < s.length && s[i] == ':') { i++; ws(i); if (i < s.length && s[i] != ',' && s[i] != '}') v = parse(i); }
                n.map_ ~= Node.Pair(k, v);
                ws(i);
                if (i < s.length && s[i] == ',') { i++; continue; }
                if (i < s.length && s[i] == '}') { i++; return n; }
                throw fail("expected ',' or '}'");
            }
        }
        if (c == '\'' || c == '"') return quoted(i, c);
        if (c == '&' || c == '*' || c == '!') throw fail("anchors, aliases and tags are not supported");
        size_t st = i;
        while (i < s.length)
        {
            char d = s[i];
            if (d == ',' || d == ']' || d == '}' || d == '[' || d == '{') break;
            if (d == ':' && (i + 1 >= s.length || " \t\r\n,]}".canFind(s[i + 1]))) break;
            if (d == '#' && i > st && (s[i - 1] == ' ' || s[i - 1] == '\t')) break;
            i++;
        }
        import std.string : strip;
        import std.array : split, join;
        auto words = s[st .. i].split.join(" ");
        return resolvePlain(words.strip);
    }

    Node quoted(ref size_t i, char q)
    {
        i++;
        auto a = appender!string;
        while (i < s.length)
        {
            char c = s[i];
            if (q == '\'' && c == '\'')
            {
                if (i + 1 < s.length && s[i + 1] == '\'') { a.put('\''); i += 2; continue; }
                i++;
                return Node(a.data);
            }
            if (q == '"' && c == '"') { i++; return Node(a.data); }
            if (q == '"' && c == '\\' && i + 1 < s.length)
            {
                char e = s[i + 1];
                i += 2;
                switch (e)
                {
                case 'n': a.put('\n'); break;
                case 't': a.put('\t'); break;
                case 'r': a.put('\r'); break;
                case '0': a.put('\0'); break;
                case '\\': a.put('\\'); break;
                case '"': a.put('"'); break;
                case '/': a.put('/'); break;
                case ' ': a.put(' '); break;
                case 'x':
                case 'u':
                case 'U':
                    size_t len = e == 'x' ? 2 : e == 'u' ? 4 : 8;
                    if (i + len > s.length) throw fail("bad escape");
                    import std.utf : encode;
                    char[4] buf;
                    auto cnt = encode(buf, cast(dchar) to!uint(s[i .. i + len], 16));
                    a.put(buf[0 .. cnt]);
                    i += len;
                    break;
                default: throw fail("unsupported escape \\" ~ e);
                }
                continue;
            }
            if (c == '\n' || c == '\r')
            {
                // line folding: a single break becomes a space
                while (i < s.length && (s[i] == '\r' || s[i] == '\n' || s[i] == ' ' || s[i] == '\t')) i++;
                a.put(' ');
                continue;
            }
            a.put(c);
            i++;
        }
        throw fail("unclosed quote");
    }
}

/// Loads a single YAML document (D-YAML compatible).
struct Loader
{
    private string src_;
    private string name_ = "<unknown>";
    private bool done_;

    /// Load from a file.
    static Loader fromFile(string filename)
    {
        import std.file : readText;
        Loader l;
        try l.src_ = readText(filename);
        catch (Exception e) throw new YAMLException("unable to open file " ~ filename ~ ": " ~ e.msg);
        l.name_ = filename;
        return l;
    }

    /// Load from a string.
    static Loader fromString(string data, string filename = "<unknown>")
    {
        Loader l;
        l.src_ = data;
        l.name_ = filename;
        return l;
    }

    /// ditto
    static Loader fromString(char[] data, string filename = "<unknown>")
    {
        return fromString(data.idup, filename);
    }

    /// Load from UTF-8 bytes.
    static Loader fromBuffer(ubyte[] data)
    {
        return fromString(cast(string) data.idup);
    }

    /// Name used in error messages.
    ref string name() return { return name_; }

    /// Load the document. Multi-document input throws.
    Node load()
    {
        Document doc;
        try doc = Document.parse(src_);
        catch (YamlEditException e)
            throw new LoaderException(name_ ~ ":" ~ to!string(e.line) ~ ": " ~ e.msg);
        auto root = fromRef(doc, doc.root, name_);
        root.origin_ = new Origin;
        root.origin_.doc = doc;
        root.origin_.snapshot = deepCopy(root);
        return root;
    }

    /// Range over documents (always one).
    bool empty() const { return done_; }
    /// ditto
    Node front() { return load(); }
    /// ditto
    void popFront() { done_ = true; }
}

// --------------------------------------------------------------------- dumper

/// Line break used by fresh output (D-YAML name).
enum LineBreak
{
    unix,
    windows,
    macintosh
}

/// Returns a `Dumper` (D-YAML entry point).
auto dumper() { return Dumper(); }

/// Writes nodes as YAML (D-YAML compatible). Loaded roots keep their formatting.
struct Dumper
{
    /// Indentation of fresh output.
    uint indent = 2;
    /// Kept for source compatibility; fresh output does not wrap.
    uint textWidth = 80;
    /// Write `---` before each document.
    bool explicitStart;
    /// Write `...` after each document.
    bool explicitEnd;
    /// Line break of fresh output.
    LineBreak lineBreak = LineBreak.unix;
    /// Kept for source compatibility.
    string name = "<unknown>";

    /// Write `documents` to the output range.
    void dump(CharacterType = char, Range)(Range range, Node[] documents...)
    {
        foreach (i, ref d; documents)
        {
            string body_ = render(d);
            if (explicitStart || documents.length > 1) put(range, "---" ~ nl);
            put(range, body_);
            if (explicitEnd) put(range, "..." ~ nl);
        }
    }

    private string nl() const
    {
        return lineBreak == LineBreak.windows ? "\r\n" : lineBreak == LineBreak.macintosh ? "\r" : "\n";
    }

    private string render(ref Node d)
    {
        if (d.origin_ !is null)
        {
            auto o = d.origin_;
            sync(o.doc, o.snapshot, d, "");
            o.snapshot = deepCopy(d);
            return o.doc.emit();
        }
        auto a = appender!string;
        emitFresh(a, d, 0, indent, nl);
        return a.data;
    }
}

// ------------------------------------------------------- sync into a Document

private string keyText(const ref Node k)
{
    if (k.nodeID != NodeID.scalar)
        throw new RepresenterException("yaml_edit.compat.dyaml only supports scalar mapping keys");
    if (k.type_ == NodeType.null_) return "null";
    return (cast() k).as!string;
}

private string child(string path, const ref Node key)
{
    auto k = keyText(key);
    if (k.canFind('"'))
        throw new RepresenterException("keys containing '\"' cannot be edited: " ~ k);
    return path.length ? path ~ ".\"" ~ k ~ "\"" : "\"" ~ k ~ "\"";
}

private string child(string path, size_t i) { return path ~ "[" ~ to!string(i) ~ "]"; }

private void scalarText(const ref Node n, out string text, out ScalarStyle style)
{
    switch (n.type_)
    {
    case NodeType.string:
        text = n.str_;
        style = ScalarStyle.preserve;
        return;
    case NodeType.null_:
        text = "null";
        style = ScalarStyle.plain;
        return;
    case NodeType.boolean:
        text = n.bool_ ? "true" : "false";
        style = ScalarStyle.plain;
        return;
    case NodeType.integer:
        text = to!string(n.long_);
        style = ScalarStyle.plain;
        return;
    case NodeType.decimal:
        text = realText(n.real_);
        style = ScalarStyle.plain;
        return;
    case NodeType.timestamp:
        text = n.str_;
        style = ScalarStyle.plain;
        return;
    default:
        throw new RepresenterException("cannot represent a node of this type");
    }
}

private string realText(real r)
{
    if (isNaN(r)) return ".nan";
    if (isInfinity(r)) return r > 0 ? ".inf" : "-.inf";
    auto t = to!string(r);
    if (!t.canFind('.') && !t.canFind('e') && !t.canFind("inf")) t ~= ".0";
    if (t.canFind('e') && !t.canFind('.'))
    {
        auto e = t.indexOf('e');
        t = t[0 .. e] ~ ".0" ~ t[e .. $];
    }
    if (t.canFind("e") && !t.canFind("e-") && !t.canFind("e+")) t = t.replace("e", "e+");
    return t;
}

private void sync(Document doc, const ref Node old, const ref Node neu, string path)
{
    if (nodeEq(old, neu)) return;
    if (path.length && doc.kind(path) == NodeKind.opaque && neu.nodeID != NodeID.scalar)
    {
        // a changed flow collection is rewritten in flow style on its line
        doc.setRaw(path, renderFlow(neu));
        return;
    }
    if (old.type_ == NodeType.mapping && neu.type_ == NodeType.mapping)
    {
        foreach (ref p; old.map_)
            if (!hasKey(neu, p.key)) doc.remove(child(path, p.key));
        foreach (ref p; neu.map_)
        {
            auto op = findKey(old, p.key);
            if (op is null) addValue(doc, child(path, p.key), p.value);
            else sync(doc, op.value, p.value, child(path, p.key));
        }
        return;
    }
    if (old.type_ == NodeType.sequence && neu.type_ == NodeType.sequence && neu.seq_.length)
    {
        syncSeq(doc, old, neu, path);
        return;
    }
    if (path.length == 0)
        throw new RepresenterException("cannot replace the document root of a loaded document");
    if (neu.nodeID == NodeID.scalar && old.nodeID == NodeID.scalar)
    {
        string t;
        ScalarStyle st;
        scalarText(neu, t, st);
        doc.set(path, t, st);
        return;
    }
    replaceValue(doc, path, neu);
}

private bool hasKey(const ref Node m, const ref Node k) { return findKey(m, k) !is null; }

private const(Node.Pair)* findKey(const ref Node m, const ref Node k)
{
    foreach (ref p; m.map_) if (nodeEq(p.key, k)) return &p;
    return null;
}

private void syncSeq(Document doc, const ref Node old, const ref Node neu, string path)
{
    auto a = old.seq_, b = neu.seq_;
    if (a.length == b.length)
    {
        foreach (i; 0 .. a.length) sync(doc, a[i], b[i], child(path, i));
        return;
    }
    // longest common subsequence of equal items
    auto n = a.length, m = b.length;
    auto L = new size_t[][](n + 1, m + 1);
    foreach_reverse (i; 0 .. n)
        foreach_reverse (j; 0 .. m)
            L[i][j] = nodeEq(a[i], b[j]) ? L[i + 1][j + 1] + 1
                : (L[i + 1][j] >= L[i][j + 1] ? L[i + 1][j] : L[i][j + 1]);
    bool[] keepA = new bool[n], keepB = new bool[m];
    size_t i = 0, j = 0;
    while (i < n && j < m)
    {
        if (nodeEq(a[i], b[j])) { keepA[i] = keepB[j] = true; i++; j++; }
        else if (L[i + 1][j] >= L[i][j + 1]) i++;
        else j++;
    }
    // Pair unmatched old and new items that sit in the same gap: edit them in place.
    size_t[] remove_;
    size_t[] insert_;
    i = 0; j = 0;
    size_t[2][] edits; // [oldIndex, newIndex]
    while (i < n || j < m)
    {
        size_t[] ga, gb;
        while (i < n && !keepA[i]) ga ~= i++;
        while (j < m && !keepB[j]) gb ~= j++;
        size_t k = 0;
        for (; k < ga.length && k < gb.length; k++) edits ~= [ga[k], gb[k]];
        foreach (x; ga[k .. $]) remove_ ~= x;
        foreach (y; gb[k .. $]) insert_ ~= y;
        if (i < n && j < m) { i++; j++; }
    }
    // edits first (old indexes still valid), then removals from the end, then inserts ascending
    foreach (e; edits) sync(doc, a[e[0]], b[e[1]], child(path, e[0]));
    foreach_reverse (x; remove_) doc.removeItem(path, x);
    foreach (y; insert_) insertValue(doc, path, y, b[y]);
}

private void insertValue(Document doc, string path, size_t index, const ref Node v)
{
    final switch (v.nodeID)
    {
    case NodeID.scalar:
        string t;
        ScalarStyle st;
        scalarText(v, t, st);
        doc.insertItem(path, index, t);
        if (st != ScalarStyle.preserve) doc.set(child(path, index), t, st);
        break;
    case NodeID.mapping:
        if (v.map_.length == 0 || v.map_[0].value.nodeID != NodeID.scalar)
        {
            doc.insertItem(path, index, "");
            replaceValue(doc, child(path, index), v);
            break;
        }
        string t;
        ScalarStyle st;
        scalarText(v.map_[0].value, t, st);
        string[2][] first = [[keyText(v.map_[0].key), t]];
        doc.insertItem(path, index, first);
        auto ip = child(path, index);
        if (st != ScalarStyle.preserve) doc.set(child(ip, v.map_[0].key), t, st);
        foreach (ref p; v.map_[1 .. $]) addValue(doc, child(ip, p.key), p.value);
        break;
    case NodeID.sequence:
        doc.insertItem(path, index, "");
        replaceValue(doc, child(path, index), v);
        break;
    case NodeID.invalid:
        throw new RepresenterException("cannot dump an invalid node");
    }
}

private void addValue(Document doc, string path, const ref Node v)
{
    final switch (v.nodeID)
    {
    case NodeID.scalar:
        string t;
        ScalarStyle st;
        scalarText(v, t, st);
        doc.set(path, t, st);
        break;
    case NodeID.mapping:
        doc.setEmpty(path, NodeKind.mapping);
        foreach (ref p; v.map_) addValue(doc, child(path, p.key), p.value);
        break;
    case NodeID.sequence:
        doc.setEmpty(path, NodeKind.sequence);
        foreach (i, ref c; v.seq_) insertValue(doc, path, i, c);
        break;
    case NodeID.invalid:
        throw new RepresenterException("cannot dump an invalid node");
    }
}

private void replaceValue(Document doc, string path, const ref Node v)
{
    // Replacing a value keeps its key line (and trailing comment).
    final switch (v.nodeID)
    {
    case NodeID.scalar:
        string t;
        ScalarStyle st;
        scalarText(v, t, st);
        doc.set(path, t, st == ScalarStyle.preserve ? ScalarStyle.preserve : st);
        break;
    case NodeID.mapping:
    case NodeID.sequence:
        addValue(doc, path, v);
        break;
    case NodeID.invalid:
        throw new RepresenterException("cannot dump an invalid node");
    }
}

// --------------------------------------------------------------- fresh output

private string scalarOut(const ref Node n)
{
    string t;
    ScalarStyle st;
    scalarText(n, t, st);
    if (st == ScalarStyle.plain) return t;
    return quoteScalar(t);
}

private void emitFresh(R)(ref R a, const ref Node n, size_t ind, size_t step, string nl)
{
    string pad(size_t k) { auto p = appender!string; foreach (_; 0 .. k) p.put(' '); return p.data; }
    switch (n.nodeID)
    {
    case NodeID.mapping:
        if (n.map_.length == 0) { a.put("{}" ~ nl); return; }
        foreach (ref p; n.map_)
        {
            a.put(pad(ind) ~ quoteScalar(keyText(p.key)) ~ ":");
            emitChild(a, p.value, ind, step, nl, false);
        }
        return;
    case NodeID.sequence:
        if (n.seq_.length == 0) { a.put("[]" ~ nl); return; }
        foreach (ref c; n.seq_)
        {
            a.put(pad(ind) ~ "-");
            emitChild(a, c, ind, step, nl, true);
        }
        return;
    case NodeID.scalar:
        a.put(scalarOut(n) ~ nl);
        return;
    default:
        throw new RepresenterException("cannot dump an invalid node");
    }
}

private void emitChild(R)(ref R a, const ref Node v, size_t ind, size_t step, string nl, bool inSeq)
{
    if (v.nodeID == NodeID.scalar) { a.put(" " ~ scalarOut(v) ~ nl); return; }
    if (v.length == 0) { a.put(v.nodeID == NodeID.mapping ? " {}" ~ nl : " []" ~ nl); return; }
    if (inSeq && v.nodeID == NodeID.mapping)
    {
        // "- key: value" with the remaining keys aligned under the first
        auto b = appender!string;
        emitFresh(b, v, ind + step, step, nl);
        a.put(" " ~ b.data[ind + step .. $]);
        return;
    }
    a.put(nl);
    emitFresh(a, v, ind + step, step, nl);
}

private string renderFlow(const ref Node n)
{
    if (n.nodeID == NodeID.sequence)
        return "[" ~ n.seq_.map!(c => renderFlow(c)).join(", ") ~ "]";
    if (n.nodeID == NodeID.mapping)
        return "{" ~ n.map_.map!(p => renderFlow(p.key) ~ ": " ~ renderFlow(p.value)).join(", ") ~ "}";
    if (n.nodeID == NodeID.scalar)
    {
        auto t = scalarOut(n);
        if (t.length && t[0] != '\'' && t[0] != '"' && (t.canFind(',') || t.canFind('[') || t.canFind(']')
            || t.canFind('{') || t.canFind('}')))
            t = "'" ~ t.replace("'", "''") ~ "'";
        return t;
    }
    return "<invalid>";
}

private string join(R)(R r, string sep)
{
    import std.array : join_ = join;
    return join_(r.array, sep);
}
