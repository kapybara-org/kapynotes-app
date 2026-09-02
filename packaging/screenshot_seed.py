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

# Milliseconds. Fixed so a rerun produces byte-identical scenes.
DAY = 86_400_000
NOW = 1_772_452_800_000  # 2026-03-02 12:00 UTC

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
    "trip": """Lisbon trip

Flights for two
flights = 412 eur
flights to usd

Hotel, 7 nights
nightly = 128 eur
nightly * 7

Food and getting around // rough guess
daily = 55 eur
daily * 7

total
total to usd""",
    "remodel": """Kitchen remodel

Cabinets
cabinets = 4,200

Counters and sink
counters = 2,850

Appliances // showroom sale
appliances = 3,100 - 15%

subtotal = cabinets + counters + appliances
tax = subtotal * 8%
subtotal + tax""",
    "roast": """Sunday roast for six

Recipe serves four
scale = 6 / 4

Beef, 800 g a head
beef = 800 g * 6
beef to kg

Potatoes
1.2 kg * scale

Stock
500 ml * scale

Oven
180 c to f

Rest before carving
25 min""",
    "invoice": """March invoice

Design sprint
hours = 38
rate = 95 usd
hours * rate

Retainer
retainer = 1,200 usd

subtotal = hours * rate + retainer
Agreed discount // said yes on the call
due = subtotal - 5%

Client pays in euros
due to eur""",
}

ORDER = ["trip", "remodel", "roast", "invoice"]

selected = os.environ.get("SEED_SELECTED", "trip")
if selected not in NOTES:
    sys.exit(f"unknown seed note {selected!r}; expected one of {', '.join(ORDER)}")

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
            "body": NOTES[key],
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
            "fetchedAt": NOW,
            "rates": RATES_PER_USD,
        },
        "sidebarVisible.v1": True,
    },
    sys.stdout,
    indent=2,
)
