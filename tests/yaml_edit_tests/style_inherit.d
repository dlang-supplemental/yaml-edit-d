/// New scalars inherit sibling style (regression: antorareg quoted ./lib/... next to plain items).
module yaml_edit_tests.style_inherit;

import yaml_edit;

private string after(string src, void delegate(Document) edit)
{
    auto d = Document.parse(src);
    edit(d);
    return d.emit();
}

unittest // playbook with plain ./lib entries: appended and inserted items stay plain
{
    auto src = import("playbook-local-ext.yml");
    auto d = Document.parse(src);
    d.appendItem("antora.extensions", "./lib/index.js", "antorareg");
    d.insertItem("antora.extensions", 1, "./lib/first.js");
    d.insertItem("antora.extensions", 0, "./lib/zero.js"); // nearest item is a forced-quote '@antora/...'

    assert(d.emit() ==
        "site:\n  title: Docs\nantora:\n  extensions:\n" ~
        "    - ./lib/zero.js\n" ~
        "    - '@antora/lunr-extension'\n" ~
        "    - ./lib/first.js\n" ~
        "    - ./lib/tabs-block.js\n" ~
        "    - ./lib/glossary.js   # antorareg\n" ~
        "    - require: ./lib/collector.js\n      enabled: true\n" ~
        "    - ./lib/index.js  # antorareg\n", d.emit());
}

unittest // mapping items: new require values copy plain siblings; forced quotes do not vote
{
    auto src = "ext:\n  - require: '@antora/a'\n  - require: ./lib/b.js\n  - require: ./lib/c.js\n";
    assert(after(src, (d) { d.appendItem("ext", [["require", "./lib/d.js"]]); })
        == src ~ "  - require: ./lib/d.js\n");
    // no item has the key: other values in sibling items vote
    auto src2 = "ext:\n  - require: 'x'\n";
    assert(after(src2, (d) { d.appendItem("ext", [["path", "p"]]); }) == src2 ~ "  - path: 'p'\n");
}

unittest // deliberately quoted siblings are copied, single and double
{
    assert(after("l:\n  - 'a'\n  - 'b'\n", (d) { d.appendItem("l", "c"); }) == "l:\n  - 'a'\n  - 'b'\n  - 'c'\n");
    assert(after("l:\n  - \"a\"\n  - \"b\"\n", (d) { d.appendItem("l", "c"); }) == "l:\n  - \"a\"\n  - \"b\"\n  - \"c\"\n");
    // majority wins over the nearest sibling
    assert(after("l:\n  - 'a'\n  - 'b'\n  - c\n", (d) { d.appendItem("l", "d"); }) == "l:\n  - 'a'\n  - 'b'\n  - c\n  - 'd'\n");
}

unittest // a tie goes to the nearest sibling
{
    auto src = "l:\n  - 'a'\n  - b\n";
    assert(after(src, (d) { d.appendItem("l", "c"); }) == src ~ "  - c\n");
    assert(after(src, (d) { d.insertItem("l", 0, "c"); }) == "l:\n  - 'c'\n  - 'a'\n  - b\n");
}

unittest // safety still wins: type-changing or unsafe values are quoted in the inherited quote style
{
    auto plain = "l:\n  - a\n  - b\n";
    assert(after(plain, (d) { d.appendItem("l", "yes"); }) == plain ~ "  - 'yes'\n");
    assert(after(plain, (d) { d.appendItem("l", "1.0"); }) == plain ~ "  - '1.0'\n");
    assert(after(plain, (d) { d.appendItem("l", "~"); }) == plain ~ "  - '~'\n");
    assert(after(plain, (d) { d.appendItem("l", "@x"); }) == plain ~ "  - '@x'\n");
    assert(after(plain, (d) { d.appendItem("l", "a: b"); }) == plain ~ "  - 'a: b'\n");
    auto dq = "l:\n  - \"a\"\n";
    assert(after(dq, (d) { d.appendItem("l", "yes"); }) == dq ~ "  - \"yes\"\n");
}

unittest // set on a new key copies sibling values, then the document, else plain
{
    assert(after("m:\n  a: 'x'\n  b: 'y'\n", (d) { d.set("m.c", "z"); }) == "m:\n  a: 'x'\n  b: 'y'\n  c: 'z'\n");
    assert(after("m:\n  a: '@x'\n  b: y\n", (d) { d.set("m.c", "./z"); }) == "m:\n  a: '@x'\n  b: y\n  c: ./z\n");
    // no siblings: the same key elsewhere in the document
    assert(after("a:\n  url: \"u1\"\nb: {}\n", (d) { d.set("c.url", "u2"); })
        == "a:\n  url: \"u1\"\nb: {}\nc:\n  url: \"u2\"\n");
    // nothing votes: plain
    assert(after("a: '@x'\n", (d) { d.set("b.c", "./p"); }) == "a: '@x'\nb:\n  c: ./p\n");
    assert(after("", (d) { d.set("k", "v"); }) == "k: v\n");
}

unittest // existing values keep their own style regardless of siblings
{
    auto src = "a: 'x'\nb: \"y\"\nc: z\nd: w\n";
    assert(after(src, (d) { d.set("a", "p"); d.set("b", "q"); d.set("c", "r"); })
        == "a: 'p'\nb: \"q\"\nc: r\nd: w\n");
    assert(after("l:\n  - 'a'\n  - b\n", (d) { d.set("l[1]", "c"); d.set("l[0]", "d"); }) == "l:\n  - 'd'\n  - c\n");
}
