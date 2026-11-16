// Word (macOS + Windows) and Outlook clipboard payloads, synthesized from the structure Office writes.
import { writeFixture, cfHtml, samplePng } from './common.mjs';

const png = samplePng(200, 120, 1);
const WORD_NS = 'xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w="urn:schemas-microsoft-com:office:word" xmlns:m="http://schemas.microsoft.com/office/2004/12/omml" xmlns="http://www.w3.org/TR/REC-html40"';

const wordStyles = `<style>
<!--
 /* Font Definitions */
 @font-face
	{font-family:"Cambria Math";
	panose-1:2 4 5 3 5 4 6 3 2 4;}
@font-face
	{font-family:Calibri;
	panose-1:2 15 5 2 2 2 4 3 2 4;}
@font-face
	{font-family:Symbol;
	panose-1:5 5 1 2 1 7 5 2 2 2;}
@font-face
	{font-family:"Courier New";
	panose-1:2 7 3 9 2 2 5 2 4 4;}
 /* Style Definitions */
 p.MsoNormal, li.MsoNormal, div.MsoNormal
	{mso-style-unhide:no;
	mso-style-qformat:yes;
	margin-top:0in;
	margin-right:0in;
	margin-bottom:8.0pt;
	margin-left:0in;
	line-height:107%;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;
	mso-ascii-font-family:Calibri;
	mso-fareast-font-family:Calibri;
	mso-hansi-font-family:Calibri;
	mso-bidi-font-family:"Times New Roman";}
h1
	{mso-style-priority:9;
	mso-style-unhide:no;
	mso-style-qformat:yes;
	mso-style-link:"Heading 1 Char";
	margin-top:12.0pt;
	margin-right:0in;
	margin-bottom:0in;
	margin-left:0in;
	line-height:107%;
	page-break-after:avoid;
	font-size:16.0pt;
	font-family:"Calibri Light",sans-serif;
	color:#2F5496;
	font-weight:normal;}
p.MsoListParagraph, li.MsoListParagraph, div.MsoListParagraph
	{mso-style-priority:34;
	mso-style-unhide:no;
	mso-style-qformat:yes;
	margin-top:0in;
	margin-right:0in;
	margin-bottom:8.0pt;
	margin-left:.5in;
	mso-add-space:auto;
	line-height:107%;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
p.MsoListParagraphCxSpFirst, li.MsoListParagraphCxSpFirst, div.MsoListParagraphCxSpFirst
	{mso-style-priority:34;
	mso-style-unhide:no;
	mso-style-qformat:yes;
	mso-style-type:export-only;
	margin-top:0in;
	margin-right:0in;
	margin-bottom:0in;
	margin-left:.5in;
	mso-add-space:auto;
	line-height:107%;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
p.MsoListParagraphCxSpMiddle, li.MsoListParagraphCxSpMiddle, div.MsoListParagraphCxSpMiddle
	{mso-style-priority:34;
	mso-style-unhide:no;
	mso-style-qformat:yes;
	mso-style-type:export-only;
	margin-top:0in;
	margin-right:0in;
	margin-bottom:0in;
	margin-left:.5in;
	mso-add-space:auto;
	line-height:107%;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
p.MsoListParagraphCxSpLast, li.MsoListParagraphCxSpLast, div.MsoListParagraphCxSpLast
	{mso-style-priority:34;
	mso-style-unhide:no;
	mso-style-qformat:yes;
	mso-style-type:export-only;
	margin-top:0in;
	margin-right:0in;
	margin-bottom:8.0pt;
	margin-left:.5in;
	mso-add-space:auto;
	line-height:107%;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
span.Heading1Char
	{mso-style-name:"Heading 1 Char";
	mso-style-priority:9;
	mso-style-unhide:no;
	mso-style-locked:yes;
	mso-style-link:"Heading 1";
	font-family:"Calibri Light",sans-serif;
	color:#2F5496;}
table.MsoNormalTable
	{mso-style-name:"Table Normal";
	mso-tstyle-rowband-size:0;
	mso-tstyle-colband-size:0;
	mso-style-noshow:yes;
	mso-style-priority:99;
	mso-style-parent:"";
	mso-padding-alt:0in 5.4pt 0in 5.4pt;
	mso-para-margin-top:0in;
	mso-para-margin-right:0in;
	mso-para-margin-bottom:8.0pt;
	mso-para-margin-left:0in;
	line-height:107%;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
table.MsoTableGrid
	{mso-style-name:"Table Grid";
	mso-tstyle-rowband-size:0;
	mso-tstyle-colband-size:0;
	mso-style-priority:39;
	mso-style-unhide:no;
	border:solid windowtext 1.0pt;
	mso-border-alt:solid windowtext .5pt;
	mso-padding-alt:0in 5.4pt 0in 5.4pt;
	mso-border-insideh:.5pt solid windowtext;
	mso-border-insidev:.5pt solid windowtext;
	mso-para-margin:0in;
	mso-pagination:widow-orphan;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
.MsoChpDefault
	{mso-style-type:export-only;
	mso-default-props:yes;
	font-family:"Calibri",sans-serif;
	mso-ascii-font-family:Calibri;
	mso-fareast-font-family:Calibri;
	mso-hansi-font-family:Calibri;}
.MsoPapDefault
	{mso-style-type:export-only;
	margin-bottom:8.0pt;
	line-height:107%;}
@page WordSection1
	{size:8.5in 11.0in;
	margin:1.0in 1.0in 1.0in 1.0in;
	mso-header-margin:.5in;
	mso-footer-margin:.5in;
	mso-paper-source:0;}
div.WordSection1
	{page:WordSection1;}
 /* List Definitions */
 @list l0
	{mso-list-id:1203962409;
	mso-list-type:hybrid;
	mso-list-template-ids:-1403542662 67698689 67698691 67698693 67698689 67698691 67698693 67698689 67698691 67698693;}
@list l0:level1
	{mso-level-number-format:bullet;
	mso-level-text:\\F0B7;
	mso-level-tab-stop:none;
	mso-level-number-position:left;
	text-indent:-.25in;
	font-family:Symbol;}
@list l0:level2
	{mso-level-number-format:bullet;
	mso-level-text:o;
	mso-level-tab-stop:none;
	mso-level-number-position:left;
	margin-left:1.0in;
	text-indent:-.25in;
	font-family:"Courier New";}
@list l1
	{mso-list-id:1678120395;
	mso-list-type:hybrid;
	mso-list-template-ids:1089146526 67698703 67698713 67698715 67698703 67698713 67698715 67698703 67698713 67698715;}
@list l1:level1
	{mso-level-tab-stop:none;
	mso-level-number-position:left;
	text-indent:-.25in;}
ol
	{margin-bottom:0in;}
ul
	{margin-bottom:0in;}
-->
</style>`;

const bullet = (cls, level, text, lfo, win) => {
  const marker = level === 1
    ? '<span style=\'font-family:Symbol;mso-fareast-font-family:Symbol;mso-bidi-font-family:Symbol\'><span style=\'mso-list:Ignore\'>·<span style=\'font:7.0pt "Times New Roman"\'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span>'
    : '<span style=\'font-family:"Courier New";mso-fareast-font-family:"Courier New"\'><span style=\'mso-list:Ignore\'>o<span style=\'font:7.0pt "Times New Roman"\'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span>';
  const wrap = (m) => win ? '<![if !supportLists]>' + m + '<![endif]>' : '<!--[if !supportLists]-->' + m + '<!--[endif]-->';
  const indent = level === 1 ? '' : 'margin-left:1.0in;';
  return `<p class=${cls} style='${indent}text-indent:-.25in;mso-list:l0 level${level} lfo${lfo}'>${wrap(marker)}${text}<o:p></o:p></p>\n`;
};
const numbered = (cls, n, text, lfo, win) => {
  const m = `<span style='mso-fareast-font-family:Calibri;mso-bidi-font-family:Calibri'><span style='mso-list:Ignore'>${n}.<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span>`;
  const wrap = win ? '<![if !supportLists]>' + m + '<![endif]>' : '<!--[if !supportLists]-->' + m + '<!--[endif]-->';
  return `<p class=${cls} style='text-indent:-.25in;mso-list:l1 level1 lfo${lfo}'>${wrap}${text}<o:p></o:p></p>\n`;
};

const td = (w, inner, extra = '') => `<td width=${w} valign=top style='width:${(w * 0.75).toFixed(1)}pt;border:solid windowtext 1.0pt;mso-border-alt:solid windowtext .5pt;padding:0in 5.4pt 0in 5.4pt'${extra ? ' ' + extra : ''}>
  <p class=MsoNormal style='margin-bottom:0in;line-height:normal'>${inner}<o:p></o:p></p>
  </td>`;

function wordBody(imgSrc, win) {
  const bl = (cls, lvl, t, lfo) => bullet(cls, lvl, t, lfo, win);
  return `<h1><a name="_Toc1">Quarterly planning notes</a><o:p></o:p></h1>
<p class=MsoNormal>Plain text, then <b style='mso-bidi-font-weight:normal'>bold</b>, <i style='mso-bidi-font-style:normal'>italic</i>, <u>underlined</u> and <b style='mso-bidi-font-weight:normal'><i style='mso-bidi-font-style:normal'><u>all three</u></i></b> runs, plus a
<a href="https://example.com/roadmap">link to the roadmap</a>.<o:p></o:p></p>
${bl('MsoListParagraphCxSpFirst', 1, 'Ship the importer', 1)}${bl('MsoListParagraphCxSpMiddle', 2, 'Word and Excel', 1)}${bl('MsoListParagraphCxSpMiddle', 2, 'Apple Notes', 1)}${bl('MsoListParagraphCxSpLast', 1, 'Write the release notes', 1)}${numbered('MsoListParagraphCxSpFirst', 1, 'Collect fixtures', 2, win)}${numbered('MsoListParagraphCxSpMiddle', 2, 'Write the parser', 2, win)}${numbered('MsoListParagraphCxSpLast', 3, 'Review with design', 2, win)}<table class=MsoTableGrid border=1 cellspacing=0 cellpadding=0 style='border-collapse:collapse;border:none;mso-border-alt:solid windowtext .5pt;mso-yfti-tbllook:1184;mso-padding-alt:0in 5.4pt 0in 5.4pt'>
 <tr style='mso-yfti-irow:0;mso-yfti-firstrow:yes'>
  ${td(208, '<b style=\'mso-bidi-font-weight:normal\'>Task</b>')}
  ${td(104, '<b style=\'mso-bidi-font-weight:normal\'>Owner</b>')}
  ${td(104, '<b style=\'mso-bidi-font-weight:normal\'>Due</b>')}
 </tr>
 <tr style='mso-yfti-irow:1'>
  ${td(208, 'Importer')}
  ${td(104, 'Asha')}
  ${td(104, '12 Dec')}
 </tr>
 <tr style='mso-yfti-irow:2;mso-yfti-lastrow:yes'>
  ${td(208, 'Release notes')}
  ${td(104, 'Ben')}
  ${td(104, '19 Dec')}
 </tr>
</table>
<p class=MsoNormal><o:p>&nbsp;</o:p></p>
<p class=MsoNormal><span style='mso-no-proof:yes'><!--[if gte vml 1]><v:shapetype id="_x0000_t75" coordsize="21600,21600" o:spt="75" o:preferrelative="t" path="m@4@5l@4@11@9@11@9@5xe" filled="f" stroked="f"><v:stroke joinstyle="miter"/><v:formulas><v:f eqn="if lineDrawn pixelLineWidth 0"/><v:f eqn="sum @0 1 0"/><v:f eqn="sum 0 0 @1"/><v:f eqn="prod @2 1 2"/><v:f eqn="prod @3 21600 pixelWidth"/><v:f eqn="prod @3 21600 pixelHeight"/><v:f eqn="sum @0 0 1"/><v:f eqn="prod @6 1 2"/><v:f eqn="prod @7 21600 pixelWidth"/><v:f eqn="sum @8 21600 0"/><v:f eqn="prod @7 21600 pixelHeight"/><v:f eqn="sum @10 21600 0"/></v:formulas><v:path o:extrusionok="f" gradientshapeok="t" o:connecttype="rect"/><o:lock v:ext="edit" aspectratio="t"/></v:shapetype><v:shape id="Picture_x0020_1" o:spid="_x0000_i1025" type="#_x0000_t75" alt="Bar chart of planned versus shipped work" style='width:150pt;height:90pt;visibility:visible;mso-wrap-style:square'><v:imagedata src="${imgSrc}" o:title="Bar chart of planned versus shipped work"/></v:shape><![endif]--><![if !vml]><img width=200 height=120 src="${imgSrc}" alt="Bar chart of planned versus shipped work" v:shapes="Picture_x0020_1"><![endif]></span><o:p></o:p></p>
`;
}

function wordHtml(imgSrc, win) {
  const head = `<html ${WORD_NS}>
<head>
<meta http-equiv=Content-Type content="text/html; charset=utf-8">
<meta name=ProgId content=Word.Document>
<meta name=Generator content="Microsoft Word 15">
<meta name=Originator content="Microsoft Word 15">
<link rel=File-List href="${win ? 'file:///C:/Users/sample/AppData/Local/Temp/msohtmlclip1/01/clip_filelist.xml' : 'file:///Users/sample/Library/Group%20Containers/UBF8T346G9.Office/msoclip1/01/clip_filelist.xml'}">
<!--[if gte mso 9]><xml>
 <o:OfficeDocumentSettings>
  <o:AllowPNG/>
 </o:OfficeDocumentSettings>
</xml><![endif]-->
<!--[if gte mso 9]><xml>
 <w:WordDocument>
  <w:View>Normal</w:View>
  <w:Zoom>0</w:Zoom>
  <w:TrackMoves/>
  <w:TrackFormatting/>
  <w:PunctuationKerning/>
  <w:ValidateAgainstSchemas/>
  <w:SaveIfXMLInvalid>false</w:SaveIfXMLInvalid>
  <w:IgnoreMixedContent>false</w:IgnoreMixedContent>
  <w:AlwaysShowPlaceholderText>false</w:AlwaysShowPlaceholderText>
  <w:DoNotPromoteQF/>
  <w:LidThemeOther>EN-US</w:LidThemeOther>
  <w:LidThemeAsian>X-NONE</w:LidThemeAsian>
  <w:LidThemeComplexScript>X-NONE</w:LidThemeComplexScript>
  <w:Compatibility>
   <w:BreakWrappedTables/>
   <w:SnapToGridInCell/>
   <w:WrapTextWithPunct/>
   <w:UseAsianBreakRules/>
   <w:DontGrowAutofit/>
   <w:SplitPgBreakAndParaMark/>
   <w:EnableOpenTypeKerning/>
   <w:DontFlipMirrorIndents/>
   <w:OverrideTableStyleHps/>
  </w:Compatibility>
  <m:mathPr>
   <m:mathFont m:val="Cambria Math"/>
   <m:brkBin m:val="before"/>
   <m:brkBinSub m:val="&#45;-"/>
   <m:smallFrac m:val="off"/>
   <m:dispDef/>
  </m:mathPr></w:WordDocument>
</xml><![endif]-->
${wordStyles}
</head>
<body lang=EN-US style='tab-interval:.5in;word-wrap:break-word'>
<!--StartFragment-->
`;
  return head + wordBody(imgSrc, win) + '<!--EndFragment-->\n</body>\n</html>';
}

const plain = (nl) => [
  'Quarterly planning notes',
  'Plain text, then bold, italic, underlined and all three runs, plus a link to the roadmap.',
  '•\tShip the importer', 'o\tWord and Excel', 'o\tApple Notes', '•\tWrite the release notes',
  '1.\tCollect fixtures', '2.\tWrite the parser', '3.\tReview with design',
  'Task\tOwner\tDue', 'Importer\tAsha\t12 Dec', 'Release notes\tBen\t19 Dec',
  '', '',
].join(nl);

const rtfHex = png.toString('hex').replace(/(.{128})/g, '$1\n');
const wordRtf = `{\\rtf1\\adeflang1025\\ansi\\ansicpg1252\\uc1\\adeff31507\\deff0\\stshfdbch31506\\stshfloch31506\\stshfhich31506\\stshfbi31507\\deflang1033\\deflangfe1033\\themelang1033\\themelangfe0\\themelangcs0
{\\fonttbl{\\f0\\fbidi \\froman\\fcharset0\\fprq2{\\*\\panose 02020603050405020304}Times New Roman;}{\\f34\\fbidi \\froman\\fcharset1\\fprq2{\\*\\panose 02040503050406030204}Cambria Math;}
{\\f37\\fbidi \\fswiss\\fcharset0\\fprq2{\\*\\panose 020f0502020204030204}Calibri;}{\\f38\\fbidi \\fswiss\\fcharset0\\fprq2{\\*\\panose 020f0302020204030204}Calibri Light;}{\\f3\\froman\\fcharset2\\fprq2{\\*\\panose 05050102010706020507}Symbol;}{\\f39\\fmodern\\fcharset0\\fprq1{\\*\\panose 02070309020205020404}Courier New;}}
{\\colortbl;\\red0\\green0\\blue0;\\red0\\green0\\blue255;\\red0\\green255\\blue255;\\red0\\green255\\blue0;\\red255\\green0\\blue255;\\red255\\green0\\blue0;\\red255\\green255\\blue0;\\red255\\green255\\blue255;\\red5\\green99\\blue193;\\red47\\green84\\blue150;}
{\\stylesheet{\\ql \\li0\\ri0\\sa160\\sl259\\slmult1\\widctlpar\\wrapdefault\\aspalpha\\aspnum\\faauto\\adjustright\\rin0\\lin0\\itap0 \\rtlch\\fcs1 \\af31507\\afs22\\alang1025 \\ltrch\\fcs0 \\f31506\\fs22\\lang1033\\langfe1033\\cgrid\\langnp1033\\langfenp1033 \\snext0 \\sqformat \\spriority0 Normal;}
{\\s1\\ql \\li0\\ri0\\sb240\\sl259\\slmult1\\keepn\\widctlpar\\wrapdefault\\aspalpha\\aspnum\\faauto\\outlinelevel0\\adjustright\\rin0\\lin0\\itap0 \\rtlch\\fcs1 \\af31503\\afs32 \\ltrch\\fcs0 \\f31502\\fs32\\cf10\\lang1033\\langfe1033\\cgrid\\langnp1033\\langfenp1033 \\sbasedon0 \\snext0 \\slink15 \\sqformat \\spriority9 heading 1;}}
{\\*\\listtable{\\list\\listtemplateid1403542662\\listhybrid{\\listlevel\\levelnfc23\\levelnfcn23\\leveljc0\\leveljcn0\\levelfollow0\\levelstartat1\\levelspace360\\levelindent0{\\leveltext\\leveltemplateid67698689\\'01\\uc0\\u8226 ;}{\\levelnumbers;}\\f3\\fbias0 \\fi-360\\li720\\jclisttab\\tx720\\lin720 }
{\\listlevel\\levelnfc23\\levelnfcn23\\leveljc0\\leveljcn0\\levelfollow0\\levelstartat1\\levelspace360\\levelindent0{\\leveltext\\leveltemplateid67698691\\'01o;}{\\levelnumbers;}\\f39\\fbias0 \\fi-360\\li1440\\jclisttab\\tx1440\\lin1440 }\\listid1203962409}
{\\list\\listtemplateid1089146526\\listhybrid{\\listlevel\\levelnfc0\\levelnfcn0\\leveljc0\\leveljcn0\\levelfollow0\\levelstartat1\\levelspace360\\levelindent0{\\leveltext\\leveltemplateid67698703\\'02\\'00.;}{\\levelnumbers\\'01;}\\fi-360\\li720\\jclisttab\\tx720\\lin720 }\\listid1678120395}}
{\\*\\listoverridetable{\\listoverride\\listid1203962409\\listoverridecount0\\ls1}{\\listoverride\\listid1678120395\\listoverridecount0\\ls2}}
\\pard\\plain \\ltrpar\\s1\\ql \\li0\\ri0\\sb240\\sl259\\slmult1\\keepn\\widctlpar\\wrapdefault\\aspalpha\\aspnum\\faauto\\outlinelevel0\\adjustright\\rin0\\lin0\\itap0 {\\rtlch\\fcs1 \\af31503\\afs32 \\ltrch\\fcs0 \\f31502\\fs32\\cf10 Quarterly planning notes\\par }
\\pard\\plain \\ltrpar\\ql \\li0\\ri0\\sa160\\sl259\\slmult1\\widctlpar\\wrapdefault\\aspalpha\\aspnum\\faauto\\adjustright\\rin0\\lin0\\itap0 {\\rtlch\\fcs1 \\af31507 \\ltrch\\fcs0 \\insrsid1 Plain text, then }{\\b Bold}{, }{\\i italic}{, }{\\ul underlined}{ and }{\\b\\i\\ul all three}{ runs, plus a }{\\field{\\*\\fldinst {HYPERLINK "https://example.com/roadmap"}}{\\fldrslt {\\cs15\\ul\\cf9 link to the roadmap}}}{.\\par }
\\pard\\plain \\ltrpar\\ql \\fi-360\\li720\\ri0\\sa0\\sl259\\slmult1\\widctlpar\\jclisttab\\tx720\\wrapdefault\\aspalpha\\aspnum\\faauto\\ls1\\adjustright\\rin0\\lin720\\itap0 {\\listtext\\f3 \\'b7\\tab}Ship the importer\\par
\\pard\\plain \\ltrpar\\ql \\fi-360\\li1440\\ri0\\sa0\\sl259\\slmult1\\widctlpar\\jclisttab\\tx1440\\wrapdefault\\aspalpha\\aspnum\\faauto\\ls1\\ilvl1\\adjustright\\rin0\\lin1440\\itap0 {\\listtext\\f39 o\\tab}Word and Excel\\par
{\\listtext\\f39 o\\tab}Apple Notes\\par
\\pard\\plain \\ltrpar\\ql \\fi-360\\li720\\ri0\\sa160\\sl259\\slmult1\\widctlpar\\jclisttab\\tx720\\wrapdefault\\aspalpha\\aspnum\\faauto\\ls1\\adjustright\\rin0\\lin720\\itap0 {\\listtext\\f3 \\'b7\\tab}Write the release notes\\par
\\pard\\plain \\ltrpar\\ql \\fi-360\\li720\\ri0\\sa0\\sl259\\slmult1\\widctlpar\\jclisttab\\tx720\\wrapdefault\\aspalpha\\aspnum\\faauto\\ls2\\adjustright\\rin0\\lin720\\itap0 {\\listtext 1.\\tab}Collect fixtures\\par
{\\listtext 2.\\tab}Write the parser\\par
\\pard\\plain \\ltrpar\\ql \\fi-360\\li720\\ri0\\sa160\\sl259\\slmult1\\widctlpar\\jclisttab\\tx720\\wrapdefault\\aspalpha\\aspnum\\faauto\\ls2\\adjustright\\rin0\\lin720\\itap0 {\\listtext 3.\\tab}Review with design\\par
\\trowd \\irow0\\irowband0\\ltrrow\\ts11\\trgaph108\\trleft-108\\trbrdrt\\brdrs\\brdrw10 \\trbrdrl\\brdrs\\brdrw10 \\trbrdrb\\brdrs\\brdrw10 \\trbrdrr\\brdrs\\brdrw10 \\trbrdrh\\brdrs\\brdrw10 \\trbrdrv\\brdrs\\brdrw10 \\cellx3000\\cellx4500\\cellx6000
\\pard\\plain \\ltrpar\\ql \\li0\\ri0\\widctlpar\\intbl\\wrapdefault\\aspalpha\\aspnum\\faauto\\adjustright\\rin0\\lin0 {\\b Task}\\cell {\\b Owner}\\cell {\\b Due}\\cell \\row
\\trowd \\irow1\\irowband1\\ltrrow\\ts11\\trgaph108\\trleft-108\\trbrdrt\\brdrs\\brdrw10 \\trbrdrl\\brdrs\\brdrw10 \\trbrdrb\\brdrs\\brdrw10 \\trbrdrr\\brdrs\\brdrw10 \\trbrdrh\\brdrs\\brdrw10 \\trbrdrv\\brdrs\\brdrw10 \\cellx3000\\cellx4500\\cellx6000
\\pard\\plain \\ltrpar\\ql \\li0\\ri0\\widctlpar\\intbl\\wrapdefault\\aspalpha\\aspnum\\faauto\\adjustright\\rin0\\lin0 Importer\\cell Asha\\cell 12 Dec\\cell \\row
\\trowd \\irow2\\irowband2\\lastrow \\ltrrow\\ts11\\trgaph108\\trleft-108\\trbrdrt\\brdrs\\brdrw10 \\trbrdrl\\brdrs\\brdrw10 \\trbrdrb\\brdrs\\brdrw10 \\trbrdrr\\brdrs\\brdrw10 \\trbrdrh\\brdrs\\brdrw10 \\trbrdrv\\brdrs\\brdrw10 \\cellx3000\\cellx4500\\cellx6000
\\pard\\plain \\ltrpar\\ql \\li0\\ri0\\widctlpar\\intbl\\wrapdefault\\aspalpha\\aspnum\\faauto\\adjustright\\rin0\\lin0 Release notes\\cell Ben\\cell 19 Dec\\cell \\row
\\pard\\plain \\ltrpar\\ql \\li0\\ri0\\sa160\\sl259\\slmult1\\widctlpar\\wrapdefault\\aspalpha\\aspnum\\faauto\\adjustright\\rin0\\lin0\\itap0 \\par
{\\pict{\\*\\picprop{\\sp{\\sn shapeType}{\\sv 75}}{\\sp{\\sn fLockAspectRatio}{\\sv 1}}}\\picscalex100\\picscaley100\\piccropl0\\piccropr0\\piccropt0\\piccropb0\\picw5292\\pich3175\\picwgoal3000\\pichgoal1800\\pngblip\\bliptag0
${rtfHex}}\\par }`;

const mac = 'Microsoft Word for Mac 16.x (synthesized)';
const win = 'Microsoft Word for Windows 16.0 (Microsoft 365) (synthesized)';

const macImg = 'file:///Users/sample/Library/Group%20Containers/UBF8T346G9.Office/msoclip1/01/clip_image001.png';
const winImg = 'file:///C:/Users/sample/AppData/Local/Temp/msohtmlclip1/01/clip_image001.png';

writeFixture({
  source: 'word', case: 'mixed-lists-table-image-mac', app: mac, platform: 'macos',
  how: 'Synthesized: what Word for Mac writes when a heading, a paragraph with bold/italic/underline runs, a nested bullet list, a numbered list, a 3x3 table and an inline picture are selected and copied.',
  notes: 'SYNTHESIZED from the structure Word emits, not captured; recapture with tool/paste_fixtures/capture_macos.swift. Facts to rely on: Word list items are <p class=MsoListParagraph*> with mso-list:lN levelM lfoK in style, a bullet/number glyph inside <span style="mso-list:Ignore"> wrapped in <!--[if !supportLists]-->...<!--[endif]--> (the glyph is Symbol-font U+F0B7 shown as "·", nested level uses Courier New "o"), <o:p> elements, MsoNormal/MsoListParagraph classes defined in the <style> block (including @list definitions), tables as <table class=MsoTableGrid> with mso-* style noise, and images as file:/// URLs to a clip_image001.png in Word\'s temp dir (that file is saved as a sidecar here; it is NOT a clipboard representation), plus VML <!--[if gte vml 1]> duplicate of the picture. Unsure: the exact set of macOS types Word for Mac registers (public.html, public.rtf and public.utf8-plain-text are certain; Word also registers private com.microsoft.* types that are not reproduced), the temp-dir path shape on Mac, and the plain-text bullet glyph (U+2022 used here).',
  items: [[
    ['public.html', wordHtml(macImg, false)],
    ['public.rtf', wordRtf],
    ['public.utf8-plain-text', plain('\n')],
  ]],
  sidecars: { 'clip_image001.png': png },
});

const winHtml = cfHtml(wordHtml(winImg, true).replace(/\n/g, '\r\n'), { version: '1.0' });
writeFixture({
  source: 'word', case: 'mixed-lists-table-image-windows', app: win, platform: 'windows',
  how: 'Synthesized: what Word for Windows writes to the clipboard for the same selection (heading, runs, nested bullets, numbered list, table, inline picture).',
  notes: 'SYNTHESIZED. "HTML Format" is the full CF_HTML payload with the Version/StartHTML/EndHTML/StartFragment/EndFragment/ header (10-digit zero-padded byte offsets, CRLF line endings, offsets computed over the UTF-8 bytes here). Windows Word writes the downlevel-revealed form <![if !supportLists]>...<![endif]> around list markers (Mac writes the <!--[if !supportLists]--> form); images point to %TEMP%\\msohtmlclip1\\01\\clip_image001.png (sidecar copy stored here). Windows Word also registers many private formats (Rich Text Format, Embed Source, Link Source, "Art::GVML ClipFormat", "Biff12"...) which are not reproduced. Unsure: whether the CF_UNICODETEXT bullet glyph is U+2022 or the Symbol private-use character; this fixture uses U+2022.',
  items: [[
    ['HTML Format', winHtml],
    ['Rich Text Format', wordRtf.replace(/\n/g, '\r\n')],
    ['CF_UNICODETEXT', plain('\r\n')],
  ]],
  sidecars: { 'clip_image001.png': png },
});

// ---------------- Outlook ----------------
const outlookStyles = `<style><!--
/* Font Definitions */
@font-face
	{font-family:"Cambria Math";
	panose-1:2 4 5 3 5 4 6 3 2 4;}
@font-face
	{font-family:Calibri;
	panose-1:2 15 5 2 2 2 4 3 2 4;}
/* Style Definitions */
p.MsoNormal, li.MsoNormal, div.MsoNormal
	{margin:0in;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
a:link, span.MsoHyperlink
	{mso-style-priority:99;
	color:#0563C1;
	text-decoration:underline;}
p.MsoListParagraph, li.MsoListParagraph, div.MsoListParagraph
	{mso-style-priority:34;
	margin-top:0in;
	margin-right:0in;
	margin-bottom:0in;
	margin-left:.5in;
	font-size:11.0pt;
	font-family:"Calibri",sans-serif;}
span.EmailStyle17
	{mso-style-type:personal-compose;
	font-family:"Calibri",sans-serif;
	color:windowtext;}
.MsoChpDefault
	{mso-style-type:export-only;
	font-family:"Calibri",sans-serif;}
@page WordSection1
	{size:8.5in 11.0in;
	margin:1.0in 1.0in 1.0in 1.0in;}
div.WordSection1
	{page:WordSection1;}
/* List Definitions */
@list l0
	{mso-list-id:1409296349;
	mso-list-type:hybrid;
	mso-list-template-ids:1318201388 67698689 67698691 67698693 67698689 67698691 67698693 67698689 67698691 67698693;}
@list l0:level1
	{mso-level-number-format:bullet;
	mso-level-text:\\F0B7;
	mso-level-tab-stop:none;
	mso-level-number-position:left;
	text-indent:-.25in;
	font-family:Symbol;}
ol
	{margin-bottom:0in;}
ul
	{margin-bottom:0in;}
--></style>`;
const outlookHtml = (win) => `<html ${WORD_NS}>
<head>
<meta http-equiv=Content-Type content="text/html; charset=utf-8">
<meta name=Generator content="Microsoft Word 15 (filtered medium)">
<!--[if !mso]><style>v\\:* {behavior:url(#default#VML);}
o\\:* {behavior:url(#default#VML);}
w\\:* {behavior:url(#default#VML);}
.shape {behavior:url(#default#VML);}
</style><![endif]-->
${outlookStyles}
<!--[if gte mso 9]><xml>
<o:shapedefaults v:ext="edit" spidmax="1026" />
</xml><![endif]--><!--[if gte mso 9]><xml>
<o:shapelayout v:ext="edit">
<o:idmap v:ext="edit" data="1" />
</o:shapelayout></xml><![endif]-->
</head>
<body lang=EN-US link="#0563C1" vlink="#954F72" style='word-wrap:break-word'>
<!--StartFragment-->
<div class=WordSection1>
<p class=MsoNormal><span style='mso-fareast-language:EN-US'>Hi team,<o:p></o:p></span></p>
<p class=MsoNormal><span style='mso-fareast-language:EN-US'><o:p>&nbsp;</o:p></span></p>
<p class=MsoNormal><span style='mso-fareast-language:EN-US'>Here is the agenda for <b>Thursday</b>; please read the <a href="https://example.com/spec">spec</a> beforehand:<o:p></o:p></span></p>
<p class=MsoListParagraph style='text-indent:-.25in;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol;mso-fareast-font-family:Symbol;mso-bidi-font-family:Symbol'><span style='mso-list:Ignore'>·<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span><![endif]><span style='mso-fareast-language:EN-US'>Fixture review<o:p></o:p></span></p>
<p class=MsoListParagraph style='text-indent:-.25in;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol;mso-fareast-font-family:Symbol;mso-bidi-font-family:Symbol'><span style='mso-list:Ignore'>·<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; </span></span></span><![endif]><span style='mso-fareast-language:EN-US'>Paste pipeline demo<o:p></o:p></span></p>
<p class=MsoNormal><span style='mso-fareast-language:EN-US'><o:p>&nbsp;</o:p></span></p>
<table class=MsoNormalTable border=1 cellspacing=0 cellpadding=0 style='border-collapse:collapse;border:none'>
<tr style='height:15.0pt'>
<td width=120 nowrap valign=bottom style='width:90.0pt;border:solid #A6A6A6 1.0pt;background:#D9E2F3;padding:0in 5.4pt 0in 5.4pt;height:15.0pt'><p class=MsoNormal><b><span style='mso-fareast-language:EN-US'>Time<o:p></o:p></span></b></p></td>
<td width=180 nowrap valign=bottom style='width:135.0pt;border:solid #A6A6A6 1.0pt;border-left:none;background:#D9E2F3;padding:0in 5.4pt 0in 5.4pt;height:15.0pt'><p class=MsoNormal><b><span style='mso-fareast-language:EN-US'>Topic<o:p></o:p></span></b></p></td>
</tr>
<tr style='height:15.0pt'>
<td width=120 nowrap valign=bottom style='width:90.0pt;border:solid #A6A6A6 1.0pt;border-top:none;padding:0in 5.4pt 0in 5.4pt;height:15.0pt'><p class=MsoNormal><span style='mso-fareast-language:EN-US'>10:00<o:p></o:p></span></p></td>
<td width=180 nowrap valign=bottom style='width:135.0pt;border-top:none;border-left:none;border-bottom:solid #A6A6A6 1.0pt;border-right:solid #A6A6A6 1.0pt;padding:0in 5.4pt 0in 5.4pt;height:15.0pt'><p class=MsoNormal><span style='mso-fareast-language:EN-US'>Fixtures<o:p></o:p></span></p></td>
</tr>
</table>
<p class=MsoNormal><span style='mso-fareast-language:EN-US'><o:p>&nbsp;</o:p></span></p>
<p class=MsoNormal><span style='mso-fareast-language:EN-US'>Thanks,<o:p></o:p></span></p>
<p class=MsoNormal><span style='mso-fareast-language:EN-US'>Asha<o:p></o:p></span></p>
</div>
<!--EndFragment-->
</body>
</html>`;
const outlookPlain = (nl) => ['Hi team,', '', 'Here is the agenda for Thursday; please read the spec beforehand:', '•\tFixture review', '•\tPaste pipeline demo', '', 'Time\tTopic', '10:00\tFixtures', '', 'Thanks,', 'Asha', ''].join(nl);

writeFixture({
  source: 'outlook', case: 'email-body-windows', app: 'Microsoft Outlook for Windows 16.0 (Microsoft 365) (synthesized)', platform: 'windows',
  how: 'Synthesized: selecting the body of a composed email (greeting, bold word, link, bullet list, small table, signature) in Outlook for Windows and copying.',
  notes: 'SYNTHESIZED. Outlook uses Word as its editor, so the HTML Format is Word-flavoured: <meta name=Generator content="Microsoft Word 15 (filtered medium)">, MsoNormal paragraphs, <div class=WordSection1>, mso-list bullets with <![if !supportLists]>, <o:p> and empty <o:p>&nbsp;</o:p> spacer paragraphs, a MsoNormalTable with per-cell inline borders. Unsure about extra private formats Outlook adds.',
  items: [[
    ['HTML Format', cfHtml(outlookHtml(true).replace(/\n/g, '\r\n'))],
    ['CF_UNICODETEXT', outlookPlain('\r\n')],
    ['Rich Text Format', '{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Calibri;}}\\pard Hi team,\\par\\par Here is the agenda for {\\b Thursday}; please read the spec beforehand:\\par {\\pntext\\f1\\\'b7\\tab}Fixture review\\par {\\pntext\\f1\\\'b7\\tab}Paste pipeline demo\\par\\par Thanks,\\par Asha\\par }'.replace(/\n/g, '\r\n')],
  ]],
});

writeFixture({
  source: 'outlook', case: 'email-body-mac', app: 'Microsoft Outlook for Mac 16.x (synthesized, guess)', platform: 'macos',
  how: 'Synthesized, GUESS: selecting part of an email body in Outlook for Mac and copying.',
  notes: 'SYNTHESIZED and a GUESS: I believe Outlook for Mac (classic) writes Word-flavoured HTML like Word for Mac, and new Outlook writes plain browser-style HTML. This reuses the Word-flavoured form. Recapture with capture_macos.swift to settle it.',
  items: [[
    ['public.html', outlookHtml(false).replace('<![if !supportLists]>', '<!--[if !supportLists]-->').replace(/<!\[endif\]>/g, '<!--[endif]-->')],
    ['public.utf8-plain-text', outlookPlain('\n')],
  ]],
});
