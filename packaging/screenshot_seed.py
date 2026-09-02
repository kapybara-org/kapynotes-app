#!/usr/bin/env python3
"""Builds the seeded `kapy-notes.json` used for App Store screenshots.

Writes the store to stdout. `SEED_SELECTED` names which note opens; the
remaining notes still populate the sidebar and the phone's notes drawer.

The rates are frozen so a screenshot never depends on the network, and are
close enough to real ones that the converted figures read as plausible.
"""

import json
import os
import sys
import time

# Note timestamps are fixed so reruns keep identical scenes.
DAY = 86_400_000
NOW = 1_772_452_800_000  # 2026-03-02 12:00 UTC

# Keep the frozen snapshot fresh for the duration of this capture. The notes
# retain fixed dates, but a historical fetchedAt makes the app replace these
# rates from the network during the five-second screenshot settle window.
RATES_FETCHED_AT = int(time.time() * 1000)

RATES_PER_USD = {
    "USD": 1.0,
    "EUR": 0.861401,
    "GBP": 0.738359,
    "JPY": 147.21,
    "INR": 83.12,
    "CAD": 1.3524,
    "AUD": 1.5087,
    "CHF": 0.7934,
    "CNY": 7.1032,
    "MXN": 18.412,
    "SEK": 9.4218,
    "SGD": 1.2841,
}

NOTES = {
    "math": """Lisbon trip budget
Five days · two travelers

Flights
212 eur
Hotel, 4 nights
88 eur * 4
Food, 5 days
36 eur * 5
Museum + tram
46 eur
Sintra day trip
58 eur
Surf lesson
72 eur
Airport transfer
24 eur
Travel buffer
60 eur

Trip total
total
total to usd""",
    "notes": """Product launch notes
Tuesday · brand and onboarding

The big idea
A notes app should feel ready before the thought disappears.

Decisions
• Keep the first screen focused on the page
• Make calculations feel native to every note
• Let Kapy guide without distracting

What people said
“It feels more like paper than software.”

Details worth keeping
• Warm paper texture
• Fast keyboard focus
• Local-first by default

Next conversation
Test the new onboarding with five writers.
Bring the strongest words into the launch copy.""",
    "checklist": """Launch day checklist
Friday · ready by 9:00 AM

Ready to ship
☑ Review App Store copy
☑ Test the welcome flow
☑ Check every screenshot total
☑ Proofread privacy details

Before we announce
☑ Publish the changelog
☐ Send the launch email
☐ Share the product story
☐ Update the press folder

After launch
☐ Watch the first reviews
☐ Reply to support notes
☐ Collect favorite use cases

Remember
• Celebrate with the team
• Save the kind messages""",
    "journal": """September 2
Evening reflection · 9:41 PM

Today
One clear idea unlocked the rest of the day.

Grateful for
• A quiet cup of coffee
• The friend who asked the right question
• A long walk after the rain

Small win
I shared work before it felt perfect, and the conversation made it better.

Tomorrow
Begin with the hardest page.
Leave the afternoon open for curiosity.
Call home before dinner.

One sentence to keep
Small, steady steps still carry me forward.""",
    "recipe": """Brown butter cookies
Scale 12 → 18 cookies

Ingredients
Butter
170 g * 18 / 12
Brown sugar
150 g * 18 / 12
Flour
220 g * 18 / 12
Chocolate
180 g * 18 / 12

Weight check
total
total to oz

Bake
180 degC to degF
Chill the dough for 30 minutes.
Bake until the edges are golden.""",
}

TABLET_NOTES = dict(NOTES)
TABLET_NOTES["math"] = TABLET_NOTES["math"].replace(
    "Trip total",
    """More plans
City transit
52 eur
Dinner out
64 eur
Bookshop stop
34 eur
Fado tickets
76 eur
Oceanarium
50 eur
Souvenirs
42 eur
Late checkout
30 eur

Trip total""",
)
TABLET_NOTES["notes"] = TABLET_NOTES["notes"].replace(
    "Next conversation",
    """Questions for Friday
• What makes a note feel instantly approachable?
• Which moments deserve a gentle Kapy nudge?
• Where can we remove one more decision?
• What should always work without a connection?
• Which words sound most like our customers?
• What would make someone tell a friend?
• Which details make the app feel trustworthy?
• How can the empty state feel more welcoming?
• What deserves a shortcut on every platform?
• What should the first minute teach naturally?

Next conversation""",
)
TABLET_NOTES["checklist"] = TABLET_NOTES["checklist"].replace(
    "After launch",
    """Store details
☑ Verify every device size
☑ Check light and dark appearance
☑ Confirm totals are never truncated
☑ Compare iOS and Android captures
☑ Check every heading at thumbnail size
☑ Confirm each mascot matches its story
☑ Remove stale production artwork
☑ Read every line as a new customer
☐ Upload the final tablet set
☐ Preview the listing one last time

After launch""",
)
TABLET_NOTES["journal"] = TABLET_NOTES["journal"].replace(
    "Tomorrow",
    """What I noticed
The best work happened after I stopped trying to rush it.
The room felt calmer once the phone was out of reach.
I laughed more than I expected to today.

What I can release
Not every loose end needs an answer tonight.
Rest is part of the work, not a reward for finishing it.

A note to myself
Protect the quiet hours in the morning.
Make room for one small adventure this week.
Keep noticing what already feels good.

Tomorrow""",
)
TABLET_NOTES["recipe"] = TABLET_NOTES["recipe"].replace(
    "Weight check",
    """Finishing touches
White sugar
100 g * 18 / 12
Vanilla
2 tsp * 18 / 12
Toasted walnuts
80 g * 18 / 12
Orange zest
6 g * 18 / 12
Sea salt
4 g * 18 / 12
Cocoa nibs
30 g * 18 / 12

Weight check""",
)

ANDROID_TABLET_NOTES = dict(NOTES)
ANDROID_TABLET_NOTES["math"] = ANDROID_TABLET_NOTES["math"].replace(
    "Trip total",
    """More plans
City transit
52 eur
Dinner out
64 eur
Bookshop stop
34 eur

Trip total""",
)
ANDROID_TABLET_NOTES["notes"] = ANDROID_TABLET_NOTES["notes"].replace(
    "Next conversation",
    """Questions for Friday
• What makes a note feel instantly approachable?
• Which moments deserve a gentle Kapy nudge?
• What should always work without a connection?

Next conversation""",
)
ANDROID_TABLET_NOTES["checklist"] = ANDROID_TABLET_NOTES["checklist"].replace(
    "After launch",
    """Store details
☑ Verify every device size
☑ Confirm totals are never truncated
☐ Upload the final tablet set

After launch""",
)
ANDROID_TABLET_NOTES["journal"] = ANDROID_TABLET_NOTES["journal"].replace(
    "Tomorrow",
    """What I noticed
The best work happened after I stopped trying to rush it.
The room felt calmer once the phone was out of reach.

Tomorrow""",
)
ANDROID_TABLET_NOTES["recipe"] = ANDROID_TABLET_NOTES["recipe"].replace(
    "Weight check",
    """Finishing touches
White sugar
100 g * 18 / 12
Vanilla
2 tsp * 18 / 12
Toasted walnuts
80 g * 18 / 12

Weight check""",
)

ORDER = ["math", "notes", "checklist", "journal", "recipe"]

SECTION_HEADINGS = {
    "Travel",
    "Experiences",
    "Little extras",
    "More plans",
    "Trip total",
    "The big idea",
    "Decisions",
    "What people said",
    "Details worth keeping",
    "Questions for Friday",
    "Next conversation",
    "Ready to ship",
    "Before we announce",
    "Store details",
    "After launch",
    "Remember",
    "Today",
    "Grateful for",
    "Small win",
    "On my mind",
    "What I noticed",
    "What I can release",
    "A note to myself",
    "Tomorrow",
    "One sentence to keep",
    "Wet ingredients",
    "Ingredients",
    "Dry ingredients",
    "Finishing touches",
    "Weight check",
    "Bake",
}


def formats_for(body):
    """Applies the app's native rich-text styles to the seeded note."""
    formats = []
    offset = 0
    for index, line in enumerate(body.split("\n")):
        end = offset + len(line)
        if line:
            if index == 0:
                formats.append({"start": offset, "end": end, "format": "heading"})
            elif index == 1:
                formats.append({"start": offset, "end": end, "format": "subtitle"})
            if line in SECTION_HEADINGS:
                formats.append({"start": offset, "end": end, "format": "bold"})
            if line.startswith("“"):
                formats.append({"start": offset, "end": end, "format": "italic"})
        offset = end + 1
    return formats

selected = os.environ.get("SEED_SELECTED", "math")
if selected not in NOTES:
    sys.exit(f"unknown seed note {selected!r}; expected one of {', '.join(ORDER)}")

layout = os.environ.get("SEED_LAYOUT", "phone")
if layout not in {"phone", "tablet", "android-tablet"}:
    sys.exit(
        "unknown seed layout; expected 'phone', 'tablet', or 'android-tablet'"
    )
notes_by_key = {
    "phone": NOTES,
    "tablet": TABLET_NOTES,
    "android-tablet": ANDROID_TABLET_NOTES,
}[layout]

# The app opens the most recently edited note, so the scene is chosen by
# timestamp rather than by the stored selection.
order = [selected] + [key for key in ORDER if key != selected]

notes = []
for index, key in enumerate(order):
    # Newest first in the sidebar, each note a plausible distance apart.
    edited = NOW - index * DAY
    notes.append(
        {
            "id": f"screenshot-{key}",
            "body": notes_by_key[key],
            "formats": formats_for(notes_by_key[key]),
            "createdAt": edited - 3 * DAY,
            "updatedAt": edited,
        }
    )

json.dump(
    {
        "notes.v1": notes,
        "selectedNote.v1": f"screenshot-{selected}",
        "rates.v1": {
            "base": "USD",
            "date": "02 Mar 2026",
            "fetchedAt": RATES_FETCHED_AT,
            "rates": RATES_PER_USD,
        },
        "sidebarVisible.v1": True,
    },
    sys.stdout,
    indent=2,
)
