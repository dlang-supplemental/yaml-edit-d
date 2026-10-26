/// The README usage example, kept compiling and correct.
module yaml_edit_tests.readme;

unittest
{
    import yaml_edit;

    auto doc = Document.parse(
        "# Site playbook\n" ~
        "site:\n" ~
        "  title: Docs   # shown in the header\n" ~
        "antora:\n" ~
        "  extensions:\n" ~
        "    - '@antora/lunr-extension'\n");

    assert(doc.get("site.title") == "Docs");
    doc.set("site.title", "Dev Docs");               // comment and spacing kept
    doc.set("site.url", "https://docs.example.org"); // missing key created
    doc.appendItem("antora.extensions", "@antora/collector-extension", "antorareg");

    assert(doc.emit() ==
        "# Site playbook\n" ~
        "site:\n" ~
        "  title: Dev Docs   # shown in the header\n" ~
        "  url: https://docs.example.org\n" ~
        "antora:\n" ~
        "  extensions:\n" ~
        "    - '@antora/lunr-extension'\n" ~
        "    - '@antora/collector-extension'  # antorareg\n", doc.emit());
}

unittest // README "Coming from D-YAML" snippet, with an Appender instead of a File
{
    import yaml_edit.compat.dyaml;
    import std.array : appender;

    auto root = Loader.fromString("site:\n  title: Docs  # header\n").load();
    root["site"]["title"] = "Dev Docs";
    auto w = appender!string();
    dumper().dump(w, root);
    assert(w.data == "site:\n  title: Dev Docs  # header\n", w.data);
}
