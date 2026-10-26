/// D-YAML as the oracle: yaml_edit.compat.dyaml must load the same values.
module yaml_edit_tests.oracle;

static import dyaml;
static import ye = yaml_edit.compat.dyaml;
import yaml_edit;
import yaml_edit_tests.canon;

private immutable string[] samples = [
    import("antora-playbook.yml"),
    import("styles.yml"),
    "a: 1\r\nb:\r\n  - x\r\n  - y  # c\r\n",
    "- a\n- b: c\n  d: e\n-   - f\n",
    "seq:\n- indentless\n- items\nnext: x\n",
    "s: \"multi\n  line\n\n  double\"\nt: 'single\n  folded'\n",
    "empty_flow: []\nempty_map: {}\nnested: {a: [1, {b: c}], 'q': \"r\"}\n",
    "k: v # comment\n# c\nlist:\n  # c\n  - 1 # c\n",
    "url: http://x.org/a#frag\ncolon: a:b\ndash: -x\n",
];

string canonDyaml(string src) { return canon(dyaml.Loader.fromString(src).load()); }
string canonCompat(string src) { return canon(ye.Loader.fromString(src).load()); }

unittest
{
    foreach (src; samples)
        assert(canonDyaml(src) == canonCompat(src),
            "\n" ~ src ~ "\ndyaml:  " ~ canonDyaml(src) ~ "\ncompat: " ~ canonCompat(src));
}

unittest // every edit result must still load in D-YAML, with the edited value
{
    auto doc = Document.parse(import("antora-playbook.yml"));
    doc.set("site.title", "it's: tricky # not a comment");
    doc.set("site.new.deep", "yes");
    doc.appendItem("antora.extensions", "multi\nline\n");
    doc.appendItem("asciidoc.extensions", [["require", "x"], ["n", "1"]]);
    doc.removeItem("content.sources", 0);
    auto root = dyaml.Loader.fromString(doc.emit()).load();
    assert(root["site"]["title"].as!string == "it's: tricky # not a comment");
    assert(root["site"]["new"]["deep"].as!string == "yes");
    assert(root["site"]["new"]["deep"].type == dyaml.NodeType.string);
    assert(root["antora"]["extensions"][3].as!string == "multi\nline\n");
    assert(root["asciidoc"]["extensions"][1]["n"].as!string == "1");
    assert(root["content"]["sources"].length == 1);
    assert(canon(root) == canonCompat(doc.emit()));
}
