/**
The same consumer code compiled against D-YAML and against
yaml_edit.compat.dyaml. Only the module alias differs, which is the
one-line import swap a real consumer makes.
*/
module yaml_edit_tests.dual;

import std.array : appender, array;
static import dyaml;
static import ye = yaml_edit.compat.dyaml;
import yaml_edit_tests.canon;

private enum string playbook = import("antora-playbook.yml");

/// Typical consumer code, written once against D-YAML's API.
private enum string consumerBody = q{
    Node root = Loader.fromString(playbook).load();

    assert(root["site"]["title"].as!string == "DLang Supplemental");
    assert(root["ui"]["bundle"]["snapshot"].as!bool);
    assert(root.containsKey("antora"));
    assert(!root.containsKey("nope"));
    assert(root["output"]["clean"].get!bool == true);
    assert(root["content"]["sources"][1]["branches"][0].as!string == "main");

    string[] reqs;
    foreach (ref Node ext; root["antora"]["extensions"])
        reqs ~= ext.nodeID == NodeID.mapping ? ext["require"].as!string : ext.as!string;
    assert(reqs == ["@antora/lunr-extension", "@dev-centr/antora-search-chat", "./lib/page-context.js"]);
    assert(root["site"].mappingKeys!string.array == ["title", "url", "start_page", "keys"]);
    assert(root["asciidoc"]["attributes"]["toc"].type == NodeType.null_);

    // edits
    root["ui"]["bundle"]["url"] = "https://example.org/ui-bundle-2.zip";
    root["ui"]["bundle"]["snapshot"] = false;
    root["antora"]["extensions"].add("@antora/collector-extension");
    auto ext = Node([Node.Pair("require", "@x/y"), Node.Pair("level", 2)]);
    root["antora"]["extensions"].add(ext);
    root["antora"]["extensions"].removeAt(0);
    root["site"]["robots"] = "allow";
    root["output"].removeAt("dir");
    root["asciidoc"]["attributes"].add("sectanchors", "");

    auto app = appender!string;
    dumper().dump(app, root);
    return app.data;
};

private string viaDyamlFn()
{
    import dyaml;
    mixin(consumerBody);
}

private string viaCompatFn()
{
    import yaml_edit.compat.dyaml; // the one-line swap
    mixin(consumerBody);
}

unittest
{
    string viaDyaml = viaDyamlFn();
    string viaCompat = viaCompatFn();

    // Same data either way.
    assert(canon(dyaml.Loader.fromString(viaDyaml).load()) == canon(dyaml.Loader.fromString(viaCompat).load()),
        "\n--- dyaml ---\n" ~ viaDyaml ~ "\n--- compat ---\n" ~ viaCompat);

    // yaml_edit keeps everything else byte-identical.
    import std.array : replace;
    auto want = playbook
        .replace("    url: https://example.org/ui-bundle.zip", "    url: https://example.org/ui-bundle-2.zip")
        .replace("snapshot: true", "snapshot: false")
        .replace("    - '@antora/lunr-extension'            # antorareg: lunr@1.0.0\n", "")
        .replace("    - require: ./lib/page-context.js\n",
            "    - require: ./lib/page-context.js\n    - '@antora/collector-extension'\n"
            ~ "    - require: '@x/y'\n      level: 2\n")
        .replace("    google_analytics: 'G-XXXXXXX'\n", "    google_analytics: 'G-XXXXXXX'\n  robots: allow\n")
        .replace("  dir: ./build/site\n", "")
        .replace("    toc: ~\n", "    toc: ~\n    sectanchors: ''\n");
    assert(viaCompat == want, "\n--- got ---\n" ~ viaCompat ~ "\n--- want ---\n" ~ want);
}
