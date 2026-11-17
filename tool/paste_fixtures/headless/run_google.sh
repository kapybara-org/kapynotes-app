#!/bin/bash
# Re-captures the Google Docs / Sheets fixtures (view-only public links) with gcapture.mjs.
#   FIXROOT=<repo>/test/fixtures/paste ./run_google.sh        (then node apply_notes.mjs for notes)
# gcapture.mjs <docs|sheets> <url> <source> <case> <mode>   mode: all | lines:N | cells:ROWSxCOLS
cd "$(dirname "$0")"
export WRITE=1 FIXROOT="${FIXROOT:?set FIXROOT}"
g() { HOW="$1" node gcapture.mjs "$2" "$3" "$4" "$5" "$6"; }
D=https://docs.google.com/document/d
S=https://docs.google.com/spreadsheets/d
g "Opened the public view-only Google Doc 'Trace Event Format' in the Docs editor in headless Chrome, clicked into the body, Cmd+Home then Shift+Down x45, Cmd+C (CDP key events carrying the editing commands)." docs $D/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/edit google-docs trace-event-format-toc-and-intro lines:45
g "Same document, Cmd+A, Cmd+C." docs $D/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/edit google-docs trace-event-format-whole-document all
g "Opened the public view-only Google Doc 'Escaping VMware Workstation through COM1', Cmd+A, Cmd+C." docs $D/1sIYgqrytPK-CFWfqDntraA_Fwi2Ov-YBgMtl5hdrYd4/edit google-docs vmware-com1-images-table all
g "Opened Google's public 'Example Spreadsheet' (Class Data) in the Sheets editor, selected 6 rows x 5 columns from A1 with Shift+Arrow, Cmd+C." sheets $S/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit google-sheets class-data-plain-view-only cells:6x5
g "Opened a public view-only Google Sheet (Anthropic's Prompt Engineering Interactive Tutorial) in the Sheets editor, selected the top-left 10x6 cells, Cmd+C." sheets $S/19jzLgRruG9kjUQNKtCg1ZjdD6l6weA6qRXG5zLIAhC8/edit google-sheets merged-cells-view-only cells:10x6
g "Opened a public view-only Google Sheet (SFF PC Master List) in the Sheets editor, selected the top-left 10x6 cells, Cmd+C." sheets $S/1AddRvGWJ_f4B6UC7_IftDiVudVc8CJ8sxLUqlxVsCz4/edit google-sheets styled-list-view-only cells:10x6
