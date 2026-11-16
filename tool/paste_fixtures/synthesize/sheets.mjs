// Excel (macOS + Windows), Numbers and Google Sheets clipboard payloads, synthesized.
import { writeFixture, cfHtml, samplePng } from './common.mjs';

// ---- one shared sheet: header row, a merged title, numbers with formats, a formula, a percentage, a merged block ----
const rows = [
  ['Q4 budget', '', '', ''],
  ['Item', 'Qty', 'Unit price', 'Total'],
  ['Notebooks', 12, 3.5, 42],
  ['Pens', 40, 0.75, 30],
  ['Desk lamp', 2, 24.99, 49.98],
  ['Total', '', '', 121.98],
];
const tsv = (nl) => rows.map(r => r.join('\t')).join(nl) + nl;

const excelCss = `<style>
<!--table
	{mso-displayed-decimal-separator:"\\.";
	mso-displayed-thousand-separator:"\\,";}
@page
	{margin:.75in .7in .75in .7in;
	mso-header-margin:.3in;
	mso-footer-margin:.3in;}
tr
	{mso-height-source:auto;}
col
	{mso-width-source:auto;}
br
	{mso-data-placement:same-cell;}
.style0
	{mso-number-format:General;
	text-align:general;
	vertical-align:bottom;
	white-space:nowrap;
	mso-rotate:0;
	mso-background-source:auto;
	mso-pattern:auto;
	color:black;
	font-size:12.0pt;
	font-weight:400;
	font-style:normal;
	text-decoration:none;
	font-family:Calibri, sans-serif;
	mso-font-charset:0;
	border:none;
	mso-protection:locked visible;
	mso-style-name:Normal;
	mso-style-id:0;}
td
	{mso-style-parent:style0;
	padding-top:1px;
	padding-right:1px;
	padding-left:1px;
	mso-ignore:padding;
	color:black;
	font-size:12.0pt;
	font-weight:400;
	font-style:normal;
	text-decoration:none;
	font-family:Calibri, sans-serif;
	mso-font-charset:0;
	mso-number-format:General;
	text-align:general;
	vertical-align:bottom;
	border:none;
	mso-background-source:auto;
	mso-pattern:auto;
	mso-protection:locked visible;
	white-space:nowrap;
	mso-rotate:0;}
.xl65
	{mso-style-parent:style0;
	font-size:16.0pt;
	font-weight:700;
	text-align:center;
	mso-protection:locked visible;}
.xl66
	{mso-style-parent:style0;
	font-weight:700;
	text-align:center;
	border-top:none;
	border-right:none;
	border-bottom:.5pt solid black;
	border-left:none;
	background:#D9E1F2;
	mso-pattern:black none;}
.xl67
	{mso-style-parent:style0;
	mso-number-format:"\\0022\$\\0022\\#\\,\\#\\#0\\.00";}
.xl68
	{mso-style-parent:style0;
	font-weight:700;
	mso-number-format:"\\0022\$\\0022\\#\\,\\#\\#0\\.00";
	border-top:.5pt solid black;}
.xl69
	{mso-style-parent:style0;
	font-weight:700;
	border-top:.5pt solid black;}
-->
</style>`;

const excelBody = `<table border=0 cellpadding=0 cellspacing=0 width=372 style='border-collapse:collapse;table-layout:fixed;width:279pt'>
 <col width=108 style='mso-width-source:userset;mso-width-alt:3456;width:81pt'>
 <col width=64 span=3 style='width:48pt'>
 <tr height=21 style='height:16.0pt'>
  <td colspan=4 height=21 class=xl65 width=372 style='height:16.0pt;width:279pt'>Q4 budget</td>
 </tr>
 <tr height=20 style='height:16.0pt'>
  <td height=20 class=xl66 style='height:16.0pt'>Item</td>
  <td class=xl66 style='border-left:none'>Qty</td>
  <td class=xl66 style='border-left:none'>Unit price</td>
  <td class=xl66 style='border-left:none'>Total</td>
 </tr>
 <tr height=20 style='height:16.0pt'>
  <td height=20 style='height:16.0pt'>Notebooks</td>
  <td align=right x:num>12</td>
  <td class=xl67 align=right x:num="3.5">$3.50</td>
  <td class=xl67 align=right x:num="42" x:fmla="=B3*C3">$42.00</td>
 </tr>
 <tr height=20 style='height:16.0pt'>
  <td height=20 style='height:16.0pt'>Pens</td>
  <td align=right x:num>40</td>
  <td class=xl67 align=right x:num="0.75">$0.75</td>
  <td class=xl67 align=right x:num="30" x:fmla="=B4*C4">$30.00</td>
 </tr>
 <tr height=20 style='height:16.0pt'>
  <td height=20 style='height:16.0pt'>Desk lamp</td>
  <td align=right x:num>2</td>
  <td class=xl67 align=right x:num="24.989999999999998">$24.99</td>
  <td class=xl67 align=right x:num="49.979999999999997" x:fmla="=B5*C5">$49.98</td>
 </tr>
 <tr height=20 style='height:16.0pt'>
  <td colspan=3 height=20 class=xl69 style='height:16.0pt'>Total</td>
  <td class=xl68 align=right x:num="121.97999999999999" x:fmla="=SUM(D3:D5)">$121.98</td>
 </tr>
 <![if supportMisalignedColumns]>
 <tr height=0 style='display:none'>
  <td width=108 style='width:81pt'></td>
  <td width=64 style='width:48pt'></td>
  <td width=64 style='width:48pt'></td>
  <td width=64 style='width:48pt'></td>
 </tr>
 <![endif]>
</table>`;

const excelHtml = `<html xmlns:v="urn:schemas-microsoft-com:vml"
xmlns:o="urn:schemas-microsoft-com:office:office"
xmlns:x="urn:schemas-microsoft-com:office:excel"
xmlns="http://www.w3.org/TR/REC-html40">

<head>
<meta http-equiv=Content-Type content="text/html; charset=utf-8">
<meta name=ProgId content=Excel.Sheet>
<meta name=Generator content="Microsoft Excel 15">
<link rel=File-List href="clip_filelist.xml">
${excelCss}
</head>

<body link="#0563C1" vlink="#954F72">
<!--StartFragment-->
${excelBody}
<!--EndFragment-->
</body>

</html>`;

const rangePng = samplePng(372, 100, 3);

writeFixture({
  source: 'excel', case: 'budget-range-mac', app: 'Microsoft Excel for Mac 16.x (synthesized)', platform: 'macos',
  how: 'Synthesized: A1:D6 of a small budget sheet (merged title across A1:D1, header row with fill, currency-formatted numbers, formulas =B3*C3 and =SUM(D3:D5), a merged Total label) selected and copied in Excel for Mac.',
  notes: 'SYNTHESIZED from the structure Excel writes. HTML: xmlns:x="urn:schemas-microsoft-com:office:excel", a <style> block with .xlNN classes plus mso-number-format, cells carry x:num (raw number) and x:fmla (formula) attributes, merged cells are colspan, the trailing <![if supportMisalignedColumns]> hidden spacer row, <!--StartFragment--> directly after <body>. The cell text is the formatted display value ($42.00), x:num holds the unformatted value. plain text is TSV of display values (Excel writes displayed text: "$3.50"). Excel also writes an image of the range (public.png here, drawn as a stand-in chart; real Excel renders the cells) and private BIFF/OOXML types (not reproduced; unsure which exact names Excel for Mac registers). Unsure: Mac Excel quotes TSV cells only when they contain tabs/newlines/quotes.',
  items: [[
    ['public.html', excelHtml],
    ['public.utf8-plain-text', ['Q4 budget\t\t\t', 'Item\tQty\tUnit price\tTotal', 'Notebooks\t12\t$3.50\t$42.00', 'Pens\t40\t$0.75\t$30.00', 'Desk lamp\t2\t$24.99\t$49.98', 'Total\t\t\t$121.98', ''].join('\n')],
    ['public.png', rangePng],
  ]],
});

writeFixture({
  source: 'excel', case: 'budget-range-windows', app: 'Microsoft Excel for Windows 16.0 (Microsoft 365) (synthesized)', platform: 'windows',
  how: 'Synthesized: the same A1:D6 range copied in Excel for Windows.',
  notes: 'SYNTHESIZED. Same table as the Mac fixture, with the Windows formats: "HTML Format" (CF_HTML, CRLF, 10-digit offsets), "Csv" (Excel registers a CSV format with display text; CRLF rows), CF_UNICODETEXT as TSV with CRLF, and PNG for the picture of the range. Excel for Windows also registers Biff12/Biff8/Biff5, "Link", "Sylk", "DIF", "Rich Text Format" and many more, which are not reproduced.',
  items: [[
    ['HTML Format', cfHtml(excelHtml.replace(/\n/g, '\r\n'))],
    ['CF_UNICODETEXT', ['Q4 budget\t\t\t', 'Item\tQty\tUnit price\tTotal', 'Notebooks\t12\t$3.50\t$42.00', 'Pens\t40\t$0.75\t$30.00', 'Desk lamp\t2\t$24.99\t$49.98', 'Total\t\t\t$121.98', ''].join('\r\n')],
    ['Csv', ['Q4 budget,,,', 'Item,Qty,Unit price,Total', 'Notebooks,12,$3.50,$42.00', 'Pens,40,$0.75,$30.00', 'Desk lamp,2,$24.99,$49.98', 'Total,,,"$121.98"', ''].join('\r\n')],
    ['PNG', rangePng],
  ]],
});

// ---- Numbers ----
const numbersHtml = `<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<meta http-equiv="Content-Style-Type" content="text/css">
<title></title>
<meta name="Generator" content="Cocoa HTML Writer">
<meta name="CocoaVersion" content="2299.7">
<style type="text/css">
p.p1 {margin: 0.0px 0.0px 0.0px 0.0px; font: 10.0px 'Helvetica Neue'; color: #000000}
p.p2 {margin: 0.0px 0.0px 0.0px 0.0px; font: 10.0px 'Helvetica Neue'; color: #000000; min-height: 12.0px}
p.p3 {margin: 0.0px 0.0px 0.0px 0.0px; text-align: right; font: 10.0px 'Helvetica Neue'; color: #000000}
span.s1 {font-kerning: none}
td.td1 {width: 94.0px; margin: 0.0px 0.0px 0.0px 0.0px; padding: 2.0px 4.0px 2.0px 4.0px; background-color: #e9e9e9}
td.td2 {width: 94.0px; margin: 0.0px 0.0px 0.0px 0.0px; padding: 2.0px 4.0px 2.0px 4.0px}
</style>
</head>
<body>
<table cellspacing="0" cellpadding="0">
<tbody>
<tr>
<td valign="middle" class="td1">
<p class="p1"><span class="s1"><b>Item</b></span></p>
</td>
<td valign="middle" class="td1">
<p class="p3"><span class="s1"><b>Qty</b></span></p>
</td>
<td valign="middle" class="td1">
<p class="p3"><span class="s1"><b>Unit price</b></span></p>
</td>
</tr>
<tr>
<td valign="middle" class="td2">
<p class="p1"><span class="s1">Notebooks</span></p>
</td>
<td valign="middle" class="td2">
<p class="p3"><span class="s1">12</span></p>
</td>
<td valign="middle" class="td2">
<p class="p3"><span class="s1">$3.50</span></p>
</td>
</tr>
<tr>
<td valign="middle" class="td2">
<p class="p1"><span class="s1">Pens</span></p>
</td>
<td valign="middle" class="td2">
<p class="p3"><span class="s1">40</span></p>
</td>
<td valign="middle" class="td2">
<p class="p3"><span class="s1">$0.75</span></p>
</td>
</tr>
<tr>
<td valign="middle" class="td2">
<p class="p2"><span class="s1"></span><br></p>
</td>
<td valign="middle" class="td2">
<p class="p3"><span class="s1">52</span></p>
</td>
<td valign="middle" class="td2">
<p class="p3"><span class="s1">$1.12</span></p>
</td>
</tr>
</tbody>
</table>
</body>
</html>
`;
const numbersRtf = '{\\rtf1\\ansi\\ansicpg1252\\cocoartf2761\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fnil\\fcharset0 HelveticaNeue;\\f1\\fnil\\fcharset0 HelveticaNeue-Bold;}\n{\\colortbl;\\red255\\green255\\blue255;\\red0\\green0\\blue0;\\red233\\green233\\blue233;}\n{\\*\\expandedcolortbl;;\\csgray\\c0;\\csgray\\c93333;}\n\\deftab720\n\\trowd \\trgaph108\\trleft-108\\trbrdrt\\brdrnil \\trbrdrl\\brdrnil \\trbrdrr\\brdrnil \n\\clvertalc \\clshdrawnil \\clwWidth1880\\clftsWidth3 \\clcbpat3 \\gaph\\cellx2000\n\\clvertalc \\clshdrawnil \\clwWidth1880\\clftsWidth3 \\clcbpat3 \\gaph\\cellx4000\n\\clvertalc \\clshdrawnil \\clwWidth1880\\clftsWidth3 \\clcbpat3 \\gaph\\cellx6000\n\\pard\\intbl\\itap1\\pardeftab720\\partightenfactor0\n\\f1\\b\\fs20 \\cf2 \\kerning1\\expnd0\\expndtw0 Item\\cell \n\\pard\\intbl\\itap1\\pardeftab720\\qr\\partightenfactor0\n\\cf2 Qty\\cell \n\\pard\\intbl\\itap1\\pardeftab720\\qr\\partightenfactor0\n\\cf2 Unit price\\cell \\row\n\\pard\\tx720\\pardeftab720\\partightenfactor0\n\\f0\\b0 Notebooks\\\n}';
writeFixture({
  source: 'numbers', case: 'table-cells', app: 'Numbers 14.x for Mac (synthesized)', platform: 'macos',
  how: 'Synthesized: three rows of cells (header + 2 data rows + a totals row) selected in a Numbers table and copied.',
  notes: 'SYNTHESIZED. Numbers writes Cocoa-HTML-writer HTML (p.pN / td.tdN / span.s1 CSS classes, <meta name="Generator" content="Cocoa HTML Writer">), RTF with an RTF table, TSV plain text of the displayed values, and private com.apple.iWork.TSP* / TST* types carrying the native cell data that only Numbers itself understands (not reproduced; names uncertain). The HTML table here has no <th>; header styling is a background class. The RTF here is abbreviated (valid but truncated to the header row plus the first data cell) — treat the HTML and plain text as the faithful parts.',
  items: [[
    ['public.html', numbersHtml],
    ['public.rtf', numbersRtf],
    ['public.utf8-plain-text', 'Item\tQty\tUnit price\nNotebooks\t12\t$3.50\nPens\t40\t$0.75\n\t52\t$1.12\n'],
  ]],
});

// ---- Google Sheets (web, Chrome) ----
const esc = (s) => s.replace(/"/g, '&quot;');
const gsCell = (inner, { val, fmla, fmt, style = '', attrs = '' } = {}) => {
  const data = val !== undefined ? ` data-sheets-value="${esc(JSON.stringify(val))}"` : '';
  const f = fmla ? ` data-sheets-formula="${fmla}"` : '';
  const nf = fmt ? ` data-sheets-numberformat="${esc(JSON.stringify(fmt))}"` : '';
  return `<td style="overflow:hidden;padding:2px 3px 2px 3px;vertical-align:bottom;${style}"${data}${nf}${f}${attrs}>${inner}</td>`;
};
const S = (s) => ({ 1: 2, 2: s });
const N = (n) => ({ 1: 3, 3: n });
const cur = { 1: 2, 2: '[$$]#,##0.00', 3: 1 };
const sheetsHtml = `<google-sheets-html-origin><style type="text/css"><!--td {border: 1px solid #cccccc;overflow: hidden;padding: 2px 3px 2px 3px;vertical-align: bottom;}br {mso-data-placement:same-cell;}--></style><table xmlns="http://www.w3.org/1999/xhtml" cellspacing="0" cellpadding="0" dir="ltr" border="1" style="table-layout:fixed;font-size:10pt;font-family:Arial;width:0px;border-collapse:collapse;border:none" data-sheets-root="1" data-sheets-baot="1"><colgroup><col width="100"/><col width="100"/><col width="100"/><col width="100"/></colgroup><tbody><tr style="height:21px;">${gsCell('Q4 budget', { val: S('Q4 budget'), style: 'font-weight:bold;text-align:center;', attrs: ' rowspan="1" colspan="4"' })}</tr><tr style="height:21px;">${['Item', 'Qty', 'Unit price', 'Total'].map(h => gsCell(h, { val: S(h), style: 'font-weight:bold;background-color:#d9e1f2;' })).join('')}</tr><tr style="height:21px;">${gsCell('Notebooks', { val: S('Notebooks') })}${gsCell('12', { val: N(12), style: 'text-align:right;' })}${gsCell('$3.50', { val: N(3.5), fmt: cur, style: 'text-align:right;' })}${gsCell('$42.00', { val: N(42), fmt: cur, fmla: '=R[0]C[-2]*R[0]C[-1]', style: 'text-align:right;' })}</tr><tr style="height:21px;">${gsCell('Pens', { val: S('Pens') })}${gsCell('40', { val: N(40), style: 'text-align:right;' })}${gsCell('$0.75', { val: N(0.75), fmt: cur, style: 'text-align:right;' })}${gsCell('$30.00', { val: N(30), fmt: cur, fmla: '=R[0]C[-2]*R[0]C[-1]', style: 'text-align:right;' })}</tr><tr style="height:21px;">${gsCell('Total', { val: S('Total'), style: 'font-weight:bold;', attrs: ' rowspan="1" colspan="3"' })}${gsCell('$72.00', { val: N(72), fmt: cur, fmla: '=SUM(R[-2]C[0]:R[-1]C[0])', style: 'font-weight:bold;text-align:right;' })}</tr></tbody></table>`;
writeFixture({
  source: 'google-sheets', case: 'merged-cells-formulas-synthesized', app: 'Chrome (Google Sheets editor) (synthesized)', platform: 'macos',
  how: 'Synthesized: A1:D5 of a small Google Sheet (merged title and merged Total label, header fill, currency format, formulas) selected in the Sheets grid and copied with Cmd+C in Chrome on macOS.',
  notes: 'SYNTHESIZED. REAL view-only Sheets copies were captured headless (see google-sheets/*-view-only) and this mirrors their structure: <meta charset=utf-8> (Chrome) + <google-sheets-html-origin> custom element, a <style> with td rules, <table xmlns=... data-sheets-root="1" data-sheets-baot="1">, <colgroup>, merged cells as rowspan="1" colspan="N" on the first cell with the covered cells OMITTED (not empty), per-cell inline styles. What is NOT verified: this is a copy from a sheet with edit rights, where I believe cells additionally carry data-sheets-value (JSON {"1":type,"2":string|"3":number}), data-sheets-numberformat and data-sheets-formula (R1C1) — the real view-only captures carry none of those. Plain text is TSV; org.chromium.source-url is the sheet URL.',
  items: [[
    ['public.html', "<meta charset='utf-8'>" + sheetsHtml],
    ['public.utf8-plain-text', 'Q4 budget\t\t\t\nItem\tQty\tUnit price\tTotal\nNotebooks\t12\t$3.50\t$42.00\nPens\t40\t$0.75\t$30.00\nTotal\t\t\t$72.00'],
    ['org.chromium.source-url', 'https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit'],
  ]],
});
