/// The edits antorareg makes to antora-playbook.yml, with exact expected output.
module yaml_edit_tests.antorareg;

import std.algorithm : count;
import std.array : replace;
import std.string : splitLines;
import yaml_edit;

private enum string playbook = import("antora-playbook.yml");

/// Lines that differ between two texts of the same length in lines (or -1 when lengths differ).
private size_t changedLines(string a, string b)
{
    auto x = a.splitLines, y = b.splitLines;
    if (x.length != y.length) return size_t.max;
    size_t n;
    foreach (i; 0 .. x.length) if (x[i] != y[i]) n++;
    return n;
}

unittest // set ui.bundle.url: one line changes, style and comment kept
{
    auto doc = Document.parse(playbook);
    doc.set("ui.bundle.url", "https://example.org/ui-bundle-2.zip");
    doc.set("ui.bundle.snapshot", "false", ScalarStyle.plain);
    auto want = playbook
        .replace("url: https://example.org/ui-bundle.zip", "url: https://example.org/ui-bundle-2.zip")
        .replace("snapshot: true", "snapshot: false");
    assert(doc.emit() == want);
    assert(changedLines(playbook, doc.emit()) == 2);
}

unittest // create ui.bundle.snapshot when missing
{
    auto doc = Document.parse("ui:\n  bundle:\n    url: x.zip  # bundle\nother: 1\n");
    doc.set("ui.bundle.snapshot", "true", ScalarStyle.plain);
    assert(doc.emit() == "ui:\n  bundle:\n    url: x.zip  # bundle\n    snapshot: true\nother: 1\n");
}

unittest // add a string extension with a marker comment, copying neighbour quoting
{
    auto doc = Document.parse(playbook);
    doc.appendItem("antora.extensions", "@antora/collector-extension", "antorareg: collector@1.0.0");
    auto want = playbook.replace("    - require: ./lib/page-context.js\n",
        "    - require: ./lib/page-context.js\n    - '@antora/collector-extension'  # antorareg: collector@1.0.0\n");
    assert(doc.emit() == want, doc.emit());
}

unittest // add a require: map extension
{
    auto doc = Document.parse(playbook);
    doc.appendItem("antora.extensions", [["require", "@dev-centr/page-context"], ["mode", "full"]],
        "antorareg: page-context@0.2.0");
    auto want = playbook.replace("    - require: ./lib/page-context.js\n",
        "    - require: ./lib/page-context.js\n"
        ~ "    - require: '@dev-centr/page-context'  # antorareg: page-context@0.2.0\n"
        ~ "      mode: full\n");
    assert(doc.emit() == want, doc.emit());
}

unittest // find an extension by marker-bearing require and bump its marker
{
    auto doc = Document.parse(playbook);
    auto i = doc.findItem("antora.extensions", "@dev-centr/antora-search-chat", "require");
    assert(i == 1);
    assert(doc.comment("antora.extensions[1]") == "antorareg: search-chat@0.3.1");
    doc.setComment("antora.extensions[1]", "antorareg: search-chat@0.4.0");
    assert(doc.emit() == playbook.replace("search-chat@0.3.1", "search-chat@0.4.0"));
    assert(doc.findItem("antora.extensions", "@antora/lunr-extension") == 0);
    assert(doc.comment("antora.extensions[0]") == "antorareg: lunr@1.0.0");
}

unittest // remove an extension: only its lines go
{
    auto doc = Document.parse(playbook);
    doc.removeItem("antora.extensions", 1);
    auto want = playbook.replace(
        "    - require: '@dev-centr/antora-search-chat'   # antorareg: search-chat@0.3.1\n      index_path: /search\n", "");
    assert(doc.emit() == want, doc.emit());
}

unittest // supplemental_files: path -> list of path/contents entries
{
    auto doc = Document.parse(playbook);
    doc.set("ui.supplemental_files", "./ui");
    assert(doc.emit() == playbook.replace("supplemental_files: ./supplemental-ui", "supplemental_files: ./ui"));

    doc = Document.parse(playbook);
    doc.remove("ui.supplemental_files");
    doc.appendItem("ui.supplemental_files", [["path", "partials/footer-content.hbs"],
        ["contents", "<footer>DLang Supplemental</footer>\n"]]);
    doc.appendItem("ui.supplemental_files", [["path", "css/site-extra.css"], ["contents", "./ui/extra.css"]]);
    auto want = playbook.replace("  supplemental_files: ./supplemental-ui\n",
        "  supplemental_files:\n"
        ~ "    - path: partials/footer-content.hbs\n"
        ~ "      contents: |\n"
        ~ "        <footer>DLang Supplemental</footer>\n"
        ~ "    - path: css/site-extra.css\n"
        ~ "      contents: ./ui/extra.css\n");
    assert(doc.emit() == want, doc.emit());
    assert(doc.get("ui.supplemental_files[0].contents") == "<footer>DLang Supplemental</footer>\n");
}

unittest // reads
{
    auto doc = Document.parse(playbook);
    assert(doc.get("site.title") == "DLang Supplemental");
    assert(doc.get("site.keys.google_analytics") == "G-XXXXXXX");
    assert(doc.kind("content.sources[1].branches") == NodeKind.opaque);
    assert(doc.length("antora.extensions") == 3);
    assert(doc.get("antora.extensions[-1].require") == "./lib/page-context.js");
    assert(doc.node("asciidoc.attributes.toc").isNull);
    assert(doc.keys("ui.bundle") == ["url", "snapshot"]);
    assert(doc.get("missing.key", "fallback") == "fallback");
}
