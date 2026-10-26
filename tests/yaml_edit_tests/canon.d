/// Library-neutral rendering of a node tree, used to compare D-YAML with yaml_edit.compat.dyaml.
module yaml_edit_tests.canon;

import std.conv : to;
import std.datetime.systime : SysTime;
import std.math : isNaN;

/// Canonical text of a node from either library (same member names on both).
string canon(N)(N n)
{
    alias ID = typeof(n.nodeID());
    final switch (n.nodeID)
    {
    case ID.mapping:
        string s = "{";
        foreach (ref N k, ref N v; n) s ~= canon(k) ~ ":" ~ canon(v) ~ ",";
        return s ~ "}";
    case ID.sequence:
        string s = "[";
        foreach (ref N v; n) s ~= canon(v) ~ ",";
        return s ~ "]";
    case ID.invalid:
        return "<invalid>";
    case ID.scalar:
        alias T = typeof(n.type());
        switch (n.type)
        {
        case T.null_: return "null";
        case T.boolean: return n.as!bool ? "true" : "false";
        case T.integer: return "i" ~ to!string(n.as!long);
        case T.decimal:
            auto r = n.as!real;
            return "f" ~ (isNaN(r) ? "nan" : to!string(r));
        case T.timestamp:
            // Rounded to milliseconds: D-YAML 0.10 parses fractional seconds
            // through a float and turns ".10" into 0.0999999 s (see the report).
            import core.time : hnsecs;
            auto t = n.as!SysTime.toUTC;
            auto h = t.fracSecs.total!"hnsecs";
            t.fracSecs = hnsecs(0);
            return "t" ~ t.toISOExtString ~ "+" ~ to!string((h + 5000) / 10000) ~ "ms";
        case T.string: return "s" ~ to!string(cast(ubyte[]) n.as!string);
        default: return "?" ~ to!string(n.type);
        }
    }
}
