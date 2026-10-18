use scribe_core::onenote::{convert, import_page, imported_ids};
use scribe_core::workspace::Workspace;

const BOUNDARY: &str = "b0a7d-sample";

/// A page the way Graph returns it: positioned HTML and InkML.
fn sample() -> String {
    format!(
        r##"--{b}
Content-Type: text/html; charset=utf-8

<html lang="en-AU">
<head><title>Week 3 &amp; partial fractions</title>
<meta name="created" content="2021-05-28T10:06:00.0000000" /></head>
<body data-absolute-enabled="true" style="font-family:Calibri;font-size:11pt">
<!-- InkNode is not supported -->
<div style="position:absolute;left:48px;top:115px;width:624px">
  <p style="margin-top:0pt;margin-bottom:0pt;font-size:14pt">Partial fractions</p>
  <ul><li>split the denominator</li><li>solve for <span style="font-weight:bold">A</span>&nbsp;and B</li></ul>
  <img width="320" height="180" src="https://graph.microsoft.com/v1.0/me/onenote/resources/abc/$value" data-src-type="image/png" />
  <table><tr><td>x</td><td>f(x)</td></tr><tr><td>1</td><td>2</td></tr></table>
</div>
<div style="position:absolute;left:1800px;top:40px;width:300px"><p>Far to the right</p></div>
<img style="position:absolute;left:900px;top:600px" width="100" height="50" src="https://example/pic" data-src-type="image/jpeg" />
<object data-attachment="slides.pptx" data="https://example/att" type="application/vnd.ms-powerpoint" />
</body></html>

--{b}
Content-Type: application/inkml+xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?>
<inkml:ink xmlns:inkml="http://www.w3.org/2003/InkML">
  <inkml:definitions>
    <inkml:brush xml:id="{{pen}}{{1}}">
      <inkml:brushProperty name="width" value="75" units="himetric" />
      <inkml:brushProperty name="height" value="75" units="himetric" />
      <inkml:brushProperty name="color" value="#33CCFF" />
      <inkml:brushProperty name="transparency" value="0" />
      <inkml:brushProperty name="tip" value="ellipse" />
      <inkml:brushProperty name="rasterOp" value="copyPen" />
      <inkml:brushProperty name="ignorePressure" value="false" />
    </inkml:brush>
    <inkml:brush xml:id="{{marker}}{{2}}">
      <inkml:brushProperty name="width" value="400" units="himetric" />
      <inkml:brushProperty name="color" value="#FFFF00" />
      <inkml:brushProperty name="transparency" value="127" />
      <inkml:brushProperty name="rasterOp" value="maskPen" />
    </inkml:brush>
  </inkml:definitions>
  <inkml:traceGroup>
    <inkml:trace xml:id="t1" contextRef="#ctx" brushRef="#{{pen}}{{1}}">2540 2540 12288, 5080 2540 24576, 62421 318851 32767</inkml:trace>
    <inkml:trace xml:id="t2" contextRef="#ctx" brushRef="#{{marker}}{{2}}">0 0 0, 2540 0 0</inkml:trace>
  </inkml:traceGroup>
</inkml:ink>
--{b}--
"##,
        b = BOUNDARY
    )
}

fn content_type() -> String {
    format!("multipart/mixed; boundary=\"{BOUNDARY}\"")
}

#[test]
fn handwriting_keeps_position_pressure_and_pens() {
    let page = convert(&sample(), &content_type(), "page-1").page;
    assert_eq!(page.strokes.len(), 2);
    let pen = &page.strokes[0];
    // 2540 himetric is one inch: 96 page units.
    assert_eq!(&pen.points[..3], &[96.0, 96.0, 0.5]);
    assert_eq!(pen.points[5], 1.0);
    // Far right and far down, as on the OneNote page: nothing clipped.
    assert_eq!(pen.points[6], 2359.22);
    assert_eq!(pen.points[7], 12051.06);
    assert_eq!(pen.color, "#33CCFF");
    assert_eq!(pen.width, 2.83);
    assert!(!pen.highlighter);
    assert!(page.strokes[1].highlighter);
}

#[test]
fn text_lists_tables_and_pictures_land_where_they_were() {
    let c = convert(&sample(), &content_type(), "page-1");
    let page = &c.page;
    assert_eq!(page.title, "Week 3 & partial fractions");
    assert_eq!(page.created, "2021-05-28T10:06:00.0000000");
    assert_eq!(page.extra.get("layout").and_then(|v| v.as_str()), Some("canvas"));
    assert_eq!(page.background.kind, "blank");
    assert_eq!(page.source.as_ref().and_then(|s| s.id.as_deref()), Some("page-1"));

    assert_eq!(page.text_boxes.len(), 2);
    let main = &page.text_boxes[0];
    assert_eq!((main.x, main.y, main.width), (48.0, 115.0, 624.0));
    assert_eq!(main.text, "Partial fractions\n• split the denominator\n• solve for A and B");
    assert!((main.font_size - 18.67).abs() < 0.01);
    let right = &page.text_boxes[1];
    assert_eq!((right.x, right.y), (1800.0, 40.0));
    assert_eq!(right.text, "Far to the right");

    assert_eq!(page.tables.len(), 1);
    assert_eq!(page.tables[0].rows, vec![vec!["x", "f(x)"], vec!["1", "2"]]);
    assert_eq!(page.tables[0].x, 48.0);
    assert!(page.tables[0].y > 115.0);

    assert_eq!(c.pictures.len(), 2);
    let inline = &c.pictures[0];
    assert_eq!((inline.x, inline.width, inline.height, inline.ext.as_str()), (48.0, 320.0, 180.0, "png"));
    assert!(inline.y > 115.0, "an inline picture sits below the text before it");
    let placed = &c.pictures[1];
    assert_eq!((placed.x, placed.y, placed.ext.as_str()), (900.0, 600.0, "jpeg"));

    assert_eq!(c.skipped, vec!["slides.pptx"]);
}

#[test]
fn plain_html_without_positions_still_imports() {
    let c = convert("<html><head><title>Plain</title></head><body><p>Hello <b>there</b></p><p>Line two</p></body></html>", "text/html", "p2");
    assert!(c.page.strokes.is_empty());
    assert_eq!(c.page.text_boxes.len(), 1);
    assert_eq!(c.page.text_boxes[0].text, "Hello there\nLine two");
}

#[test]
fn importing_twice_keeps_one_copy() {
    let dir = tempfile::tempdir().unwrap();
    let ws = Workspace::open(dir.path().join("lib")).unwrap();
    let nb = ws.create_notebook("OneNote").unwrap();
    let sec = ws.create_section(&nb, "Calculus").unwrap();
    let first = import_page(&ws, &sec, &sample(), &content_type(), "page-1").unwrap();
    assert!(!first.existing);
    assert_eq!(first.pictures.len(), 2);
    let again = import_page(&ws, &sec, &sample(), &content_type(), "page-1").unwrap();
    assert!(again.existing);
    assert_eq!(again.path, first.path);
    assert_eq!(ws.list_pages(&sec).len(), 1);
    assert_eq!(imported_ids(&ws), vec!["page-1".to_string()]);
    let saved = ws.read_page(std::path::Path::new(&first.path)).unwrap();
    assert_eq!(saved.strokes.len(), 2);
    assert_eq!(saved.title, "Week 3 & partial fractions");
}
