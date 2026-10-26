module yaml_edit_tests.roundtrip;

import yaml_edit;

private immutable string[] inputs = [
    import("antora-playbook.yml"),
    import("styles.yml"),
    import("opaque.yml"),
    "",
    "\n\n# only a comment\n",
    "a: 1", // no trailing newline
    "a: 1\r\nb:\r\n  - x\r\n  - y  # c\r\n", // CRLF
    "\xEF\xBB\xBFa: 1\n", // BOM
    "%YAML 1.1\n---\na: 1\n...\n",
    "---\n- a\n- b: c\n  d: e\n-   - f\n",
    "key:    spaced   # comment\n\n\n# trailing comment\n",
    "seq:\n- indentless\n- items\nnext: x\n",
    "flow: {a: [1, 2,\n  3], b: 'x'}  # c\nafter: y\n",
    "s: |\n  keep\n\n  blank lines\n\nt: >\n  x\n",
];

unittest
{
    foreach (i, src; inputs)
    {
        auto doc = Document.parse(src);
        assert(doc.emit() == src, "round trip failed for input " ~ cast(char)('0' + i));
    }
}

unittest // untouched regions stay byte-identical after an edit, CRLF kept on new lines
{
    auto src = "a: 1\r\nb:\r\n  - x\r\n  - y  # c\r\nz: end\r\n";
    auto doc = Document.parse(src);
    doc.appendItem("b", "w");
    assert(doc.emit() == "a: 1\r\nb:\r\n  - x\r\n  - y  # c\r\n  - w\r\nz: end\r\n");
}
