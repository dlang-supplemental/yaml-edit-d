/// yaml_edit.compat.dyaml beyond the dual-library test.
module yaml_edit_tests.compat;

import std.array : appender;
import std.exception : assertThrown, collectException;
import std.algorithm : canFind;
import yaml_edit.compat.dyaml;

private string dumpStr(Node n)
{
    auto a = appender!string;
    dumper().dump(a, n);
    return a.data;
}

unittest // unsupported constructs give a clear LoaderException
{
    auto e = collectException!LoaderException(Loader.fromString("a: &x 1\nb: *x\n", "f.yml").load());
    assert(e !is null && e.msg.canFind("anchor") && e.msg.canFind("f.yml:1"), e is null ? "" : e.msg);
    assertThrown!LoaderException(Loader.fromString("a: 1\n---\nb: 2\n").load());
    assertThrown!LoaderException(Loader.fromString("a: [*x]\n").load());
}

unittest // typed strings stay strings; typed values stay plain
{
    auto root = Loader.fromString("a: x  # keep\nb: 1\n").load();
    root["a"] = "true";
    root["b"] = 2.5;
    root["c"] = 7;
    root["d"] = "007";
    assert(dumpStr(root) == "a: 'true'  # keep\nb: 2.5\nc: 7\nd: '007'\n", dumpStr(root));
    // dumping twice applies only the new changes
    root["c"] = 8;
    assert(dumpStr(root) == "a: 'true'  # keep\nb: 2.5\nc: 8\nd: '007'\n");
    assert(Loader.fromString(dumpStr(root)).load()["a"].as!string == "true");
}

unittest // sequence root, nested additions
{
    auto root = Loader.fromString("# list\n- a\n- b  # bee\n").load();
    root.add(Node([Node.Pair("k", "v"), Node.Pair("sub", Node(["x", "y"]))]));
    root[0] = "A";
    assert(dumpStr(root) == "# list\n- A\n- b  # bee\n- k: v\n  sub:\n    - x\n    - 'y'\n", dumpStr(root));
}

unittest // detached nodes use a plain block emitter
{
    auto n = Node([Node.Pair("name", "x"), Node.Pair("list", Node([1, 2])),
        Node.Pair("m", Node([Node.Pair("on", "yes")]))]);
    assert(dumpStr(n) == "name: x\nlist:\n  - 1\n  - 2\nm:\n  'on': 'yes'\n", dumpStr(n));
    auto s = Node([Node([Node.Pair("a", 1), Node.Pair("b", 2)])]);
    assert(dumpStr(s) == "- a: 1\n  b: 2\n", dumpStr(s));
}

unittest // value API
{
    auto root = Loader.fromString("a: [1, 2]\nb: {c: d}\nn: ~\nf: 1.5\n").load();
    assert(root["a"].as!(int[]) == [1, 2]);
    assert(root["a"].contains(2));
    assert(root["b"]["c"] == "d");
    assert(root["n"].type == NodeType.null_);
    assert(root["f"].as!double == 1.5);
    assert(root["f"].as!string == "1.5");
    assert(!root["f"].convertsTo!bool);
    assertThrown!NodeException(root["missing"]);
    assertThrown!NodeException(root["a"].as!string);
    assert(root.mappingKeys!string == ["a", "b", "n", "f"]);
    int sum;
    foreach (ref Node x; root["a"]) sum += x.as!int;
    assert(sum == 3);
    foreach (string k, ref Node v; root) assert(k.length == 1);
    // a changed flow collection is rewritten in flow style, on its own line only
    root["a"].add(3);
    root["b"]["e"] = "x, y";
    assert(dumpStr(root) == "a: [1, 2, 3]\nb: {c: d, e: 'x, y'}\nn: ~\nf: 1.5\n", dumpStr(root));
    assert(root.document !is null);
}

unittest // large hex/octal/binary ints (D-YAML 0.10 throws for these, see report)
{
    auto root = Loader.fromString("h: 0x100000000\no: 040000000000\nb: 0b100000000000000000000000000000000\n").load();
    assert(root["h"].as!long == 0x1_0000_0000L);
    assert(root["o"].as!long == 0x1_0000_0000L);
    assert(root["b"].as!long == 0x1_0000_0000L);
}

unittest // timestamps: exact fractions, anchored resolution (both differ from D-YAML 0.10, see report)
{
    import std.datetime.systime : SysTime;
    import core.time : msecs;
    auto root = Loader.fromString("a: 2001-12-14t21:59:43.10-05:00\nb: 2001-12-14abc\nc: 2001-12-14 21:59:43.10 -5\nd: 2002-12-14\n").load();
    assert(root["a"].as!SysTime.fracSecs == 100.msecs);
    assert(root["a"].as!SysTime == root["c"].as!SysTime);
    assert(root["b"].type == NodeType.string && root["b"].as!string == "2001-12-14abc");
    assert(root["d"].type == NodeType.timestamp);
}
