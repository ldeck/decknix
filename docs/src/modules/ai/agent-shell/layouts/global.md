# Global

Global toggles affect the **whole** sidebar rather than one section. They live
in the `Global` group of the `T` transient and are advertised in the footer.
See the [colour legend](./index.md#colour-legend-source-of-truth) for the
palette.

| Key | Toggle | States |
|-----|--------|--------|
| `O` | Org filter | `[all]` ↔ each enabled org (e.g. `[upside]`) |
| `W` | Width | `[narrow]` → `[med]` → `[wide]` |
| `K` | Keys/Toggles footer | show ↔ hide Navigate/Quick + Toggles lines |

## Org filter (`O`)

Hides every row whose repo is outside the selected org. The section counts
update to match. Default is `[all]`.

<pre class="sb-markup">
{hd}Requests (12){/}            ← all orgs
{hd}WIP (4){/}

{hd}Requests (7){/}             ← O → upside  (reapit/* hidden)
{hd}WIP (2){/}
</pre>

## Width (`W`)

Width drives truncation and the footer's layout. At `narrow`/`med` the footer
toggle groups stack vertically; at `wide` (≥48 cols) Global+Requests and
Live+WIP render **side-by-side** so the footer doesn't push content off-screen.

<pre class="sb-markup">
[med]                          [wide  ≥48 cols]
 Toggles                        Toggles
   Global: org [all] w [med]      Global: org [all] w [wide]   Requests: @ off …
   Requests: @ off ci [all] …     Live:   disp [A] view [flat]  WIP: linked [hide] …
   Live: disp [A] view [flat]
   WIP: linked [hide] stale [on]
</pre>

## Footer toggles & keys (`K`)

The footer has two parts: the **Navigate/Quick** key hints and the **Toggles**
state lines. `K` hides both so the section content gets the full height; the `T`
transient still opens and changes them while hidden.

<pre class="sb-markup">
[KEYS SHOWN]                   [KEYS HIDDEN  (K)]
 Navigate  s sessions  r req…   {hd}Requests (12){/}
 Quick     c new  k kill        …section content only…
 Toggles
   Global: org [all] w [med]
   Requests: @ off ci [all] …
</pre>

Note: the Toggles state line reflects the **current** value of every toggle by
label only (no keys) — press `T` for the interactive transient where the keys
are shown.

## Source

- Group definitions: `agent-shell/sidebar/decknix-sidebar-toggles.el`
- Footer rendering: `agent-shell/sidebar/decknix-sidebar-footer-keys.el`
