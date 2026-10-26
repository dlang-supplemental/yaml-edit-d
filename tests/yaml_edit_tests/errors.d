module yaml_edit_tests.errors;

import std.exception : assertThrown, collectException;
import std.algorithm : canFind;
import yaml_edit;

unittest
{
    assertThrown!YamlEditException(Document.parse("a: 1\n---\nb: 2\n")); // multi-document
    assertThrown!YamlEditException(Document.parse("? complex\n: key\n"));
    assertThrown!YamlEditException(Document.parse("a:\n\t- tab\n"));
    assertThrown!YamlEditException(Document.parse("a: 'unclosed\n"));
    assertThrown!YamlEditException(Document.parse("a: 1\n  b: 2\n"));

    auto doc = Document.parse("flow: {a: 1}\nanchor: &x 1\n");
    auto e = collectException!YamlEditException(doc.set("flow.a", "2"));
    assert(e !is null && e.msg.canFind("flow collection"), e is null ? "" : e.msg);
    e = collectException!YamlEditException(doc.get("missing"));
    assert(doc.emit() == "flow: {a: 1}\nanchor: &x 1\n");
    // whole opaque values can still be replaced
    doc.set("anchor", "2", ScalarStyle.plain);
    assert(doc.emit() == "flow: {a: 1}\nanchor: 2\n");
}
