import AppKit

/// Shopify admin sections driven from the phone's SHOPIFY pad. Each tap
/// retargets the Shopify admin tab that is already open in Chrome — the same
/// tab, not a second one beside it — and raises Chrome with that tab selected.
/// The store handle is read out of the tab's own URL, so a link anywhere in
/// the admin (an order, a product, settings) all land back on the store's
/// sidebar sections without the phone needing to know which store it is.
@MainActor
enum ShopifyActions {
    /// The admin's left sidebar and each section's own sub-items, in the order
    /// they appear there.
    enum Section: String, CaseIterable {
        case home = "Home"
        case orders = "Orders"
        // Orders' own sub-items, indented under it in the admin sidebar.
        case drafts = "Drafts"
        case shippingLabels = "Shipping labels"
        case abandonedCheckouts = "Abandoned checkouts"
        case products = "Products"
        case collections = "Collections"
        case inventory = "Inventory"
        case purchaseOrders = "Purchase orders"
        case transfers = "Transfers"
        case giftCards = "Gift cards"
        case customers = "Customers"
        case segments = "Segments"
        case companies = "Companies"
        case growth = "Growth"
        case attribution = "Attribution"
        case autopilot = "Autopilot"
        case campaigns = "Campaigns"
        case discounts = "Discounts"
        case content = "Content"
        case metaobjects = "Metaobjects"
        case files = "Files"
        case menus = "Menus"
        case blogPosts = "Blog posts"
        case markets = "Markets"
        case catalogs = "Catalogs"
        case rollouts = "Rollouts"
        case finance = "Finance"
        case credit = "Credit"
        case payouts = "Payouts"
        case billPay = "Bill Pay"
        case analytics = "Analytics"
        case reports = "Reports"
        case liveView = "Live View"
        case onlineStore = "Online Store"
        case apps = "Apps"
        case settings = "Settings"

        /// Appended to `https://admin.shopify.com/store/<handle>` — empty for
        /// Home, which is the admin's store root. Routes can run to more than
        /// one segment (`products/inventory`, `payments/payouts`); the whole
        /// route is used to build the URL.
        var path: String {
            switch self {
            case .home: ""
            case .orders: "orders"
            case .drafts: "draft_orders"
            case .shippingLabels: "shipping_labels"
            case .abandonedCheckouts: "checkouts"
            case .products: "products"
            case .collections: "collections"
            case .inventory: "products/inventory"
            case .purchaseOrders: "purchase_orders"
            case .transfers: "transfers"
            case .giftCards: "gift_cards"
            case .customers: "customers"
            case .segments: "customers/segments"
            case .companies: "companies"
            case .growth: "growth"
            case .attribution: "growth/attribution"
            case .autopilot: "growth/autopilot"
            case .campaigns: "growth/campaigns"
            case .discounts: "discounts"
            case .content: "content/metaobjects"
            case .metaobjects: "content/metaobjects"
            case .files: "content/files"
            case .menus: "content/menus"
            case .blogPosts: "content/articles"
            case .markets: "markets"
            case .catalogs: "catalogs"
            case .rollouts: "rollouts"
            case .finance: "payments/payouts"
            case .credit: "credit"
            case .payouts: "payments/payouts"
            case .billPay: "finance/billpay"
            case .analytics: "analytics"
            case .reports: "analytics/reports"
            case .liveView: "analytics/live"
            case .onlineStore: "themes"
            case .apps: "apps"
            case .settings: "settings"
            }
        }

        /// Lowercase form used in ActivityLog entries.
        var slug: String {
            rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    /// Resolves what the phone sent — the display name, in any casing, with
    /// spaces or underscores (so `SHOPIFY online_store` also works).
    static func section(named name: String) -> Section? {
        let wanted = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        return Section.allCases.first { $0.rawValue.lowercased() == wanted }
    }

    /// The store handle in an admin tab's URL (`…/store/purrified-air/orders`
    /// → `purrified-air`), or nil for anything that isn't a store URL.
    static func storeHandle(from url: String) -> String? {
        guard let components = URLComponents(string: url),
              components.host == "admin.shopify.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "store" else { return nil }
        let handle = parts[1]
        return handle.isEmpty ? nil : handle
    }

    /// Navigates the admin tab to `name`'s section, then reads whatever table
    /// the page is showing and hands it to `tableReady` — the phone mirrors the
    /// desktop rather than only saying it navigated. Every section is given
    /// the same treatment: whether a page is a grid is the page's business,
    /// not a list kept here that would rot. A page that isn't a table (a
    /// dashboard, cards or a chart) reports `tableNone`, which is a normal
    /// outcome rather than a failure.
    static func perform(_ name: String,
                        status: @escaping (_ message: String, _ ok: Bool) -> Void,
                        tableReady: ((_ json: String) -> Void)? = nil,
                        tableNone: ((_ section: String) -> Void)? = nil,
                        tableFailed: ((_ message: String) -> Void)? = nil) {
        guard let section = section(named: name) else {
            status("Shopify — there is no \(name) section.", false)
            return
        }
        ActivityLog.recordAction("shopify-\(section.slug)")

        // One AppleScript rather than "read the URL, then navigate": reading
        // and retargeting in the same pass means the tab that answered is the
        // tab that moves, even if the browser is busy.
        guard let handle = retargetAdminTab(to: section) else {
            status("No Shopify admin tab open in Chrome — open the admin once, then tap again.", false)
            // The phone is already on its table screen; tell it not to wait.
            tableFailed?("No Shopify admin tab open in Chrome.")
            return
        }
        // Chrome needs to be the app in front for the change to be seen; the
        // script already selected the tab and raised its window.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
            .first?.activate(options: [.activateAllWindows])
        status("Shopify — \(section.rawValue) opened (\(handle))", true)

        readTable(for: section, handle: handle) { result in
            switch result {
            case .table(let json): tableReady?(json)
            case .none: tableNone?(section.rawValue)
            case .failed: tableFailed?("Couldn't read the \(section.rawValue) page from Chrome.")
            }
        }
    }

    /// The two ways an admin page renders a grid. Most use ARIA rows; Shipping
    /// labels (and a few other pages) use a real <table>.
    private enum TableReader { case grid, table }

    private enum ReaderOutcome {
        case table(String)
        case none
        /// The tab is still on another page — the route guard returned.
        case empty
        case failed
    }

    private enum TableReadResult {
        case table(String)
        case none
        case failed
    }

    private static func preferredReader(for section: Section) -> TableReader {
        section == .shippingLabels ? .table : .grid
    }

    private static func otherReader(_ reader: TableReader) -> TableReader {
        reader == .grid ? .table : .grid
    }

    /// JavaScript that reads one page's table: its headers, its rows, and
    /// each row's own admin link. The pathname must end with the section's
    /// full route — compared segment for segment, not against the last
    /// segment alone, so multi-segment routes like `products/inventory`
    /// match — which keeps a slow navigation from handing back the previous
    /// page's table while the new one loads. Returns `NONE` when the right
    /// page is loaded but holds no grid, and an empty string while the tab is
    /// still on another page. Written as one line because it travels inside
    /// an AppleScript string.
    private static func tableJS(for section: Section, reader: TableReader) -> String {
        let page = section.rawValue
        let route = section.path
        let guardJS: String
        if route.isEmpty {
            // Home is the store root: exactly /store/<handle>, nothing deeper.
            guardJS = "const parts = location.pathname.split('/').filter(Boolean); if (parts.length > 2) return ''; "
        } else {
            let count = route.split(separator: "/").count
            guardJS = "const parts = location.pathname.split('/').filter(Boolean); if (parts.slice(-\(count)).join('/') !== '\(route)') return ''; "
        }
        switch reader {
        case .table:
            // Labels use a real <table>, with a date-group row between each
            // label row; only rows as wide as the header are labels.
            return "(() => { \(guardJS)const table = document.querySelector('table'); if (!table) return 'NONE'; const trs = Array.from(table.querySelectorAll('tr')); const header = trs[0]; if (!header) return 'NONE'; const width = header.children.length; const headers = Array.from(header.children).slice(1).map(c => c.textContent.trim()); if (headers.every(h => h === '')) return 'NONE'; const clean = (c) => (c.innerText || '').split('\\n').map(s => s.trim()).filter(Boolean).join(' · '); const out = trs.slice(1).filter(r => r.children.length === width).map(r => ({ cells: Array.from(r.children).slice(1).map(clean), href: '' })).filter(r => r.cells.some(c => c !== '')); if (out.length === 0) return 'NONE'; return JSON.stringify({ section: '\(page)', headers: headers, rows: out }); })()"
        case .grid:
            return "(() => { \(guardJS)const rows = Array.from(document.querySelectorAll('[role=row]')); const headerRow = rows.find(r => r.querySelector('[role=columnheader]')); const dataRows = rows.filter(r => r.querySelector('[role=cell]')); if (!headerRow || dataRows.length === 0) return 'NONE'; const headers = Array.from(headerRow.children).slice(1).map(c => c.textContent.trim()); if (headers.every(h => h === '')) return 'NONE'; const out = dataRows.map(r => { const cells = Array.from(r.children).slice(1).map(c => c.textContent.trim()); const link = r.querySelector('a'); return { cells: cells, href: link ? link.getAttribute('href') : '' }; }).filter(r => r.cells.some(c => c !== '')); if (out.length === 0) return 'NONE'; return JSON.stringify({ section: '\(page)', headers: headers, rows: out }); })()"
        }
    }

    /// One read with the section's preferred parser, falling back to the
    /// other when the page is loaded but the preferred parser sees no rows.
    private static func readOnce(section: Section, needle: String) -> ReaderOutcome {
        let preferred = preferredReader(for: section)
        switch run(tableJS(for: section, reader: preferred), needle: needle) {
        case .table(let json):
            return .table(json)
        case .empty:
            return .empty
        case .failed:
            return .failed
        case .none:
            // The page is right; this parser just doesn't fit how it is
            // built. Try the other one before calling the page a non-table.
            switch run(tableJS(for: section, reader: otherReader(preferred)), needle: needle) {
            case .table(let json): return .table(json)
            case .failed: return .failed
            case .none, .empty: return .none
            }
        }
    }

    private static func run(_ js: String, needle: String) -> ReaderOutcome {
        guard let result = BrowserTabReader.runJavaScript(js, inTabMatching: needle) else {
            return .failed
        }
        if result.hasPrefix("{") { return .table(result) }
        if result == "NONE" { return .none }
        return .empty
    }

    /// Reads the section's table out of the admin tab. Navigating to the
    /// section and then reading it are two separate steps, so the page can
    /// still be loading on the first try — poll until it answers. An empty
    /// answer is never an error: after the last attempt it means the page
    /// opened in Chrome but has no table to mirror.
    private static func readTable(for section: Section, handle: String,
                                  attempt: Int = 1, done: @escaping (TableReadResult) -> Void) {
        // The store handle plus the section's page makes the needle specific:
        // with two admin tabs open, only the one just navigated matches.
        let needle = "admin.shopify.com/store/\(handle)"
            + (section.path.isEmpty ? "" : "/\(section.path)")
        switch readOnce(section: section, needle: needle) {
        case .table(let json):
            done(.table(json))
        case .none:
            // Give a grid that is still rendering a moment before calling the
            // page a non-table; dashboards settle well inside this window.
            guard attempt < 8 else {
                done(.none)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                readTable(for: section, handle: handle, attempt: attempt + 1, done: done)
            }
        case .failed:
            guard attempt < 20 else {
                done(.failed)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                readTable(for: section, handle: handle, attempt: attempt + 1, done: done)
            }
        case .empty:
            guard attempt < 20 else {
                done(.none)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                readTable(for: section, handle: handle, attempt: attempt + 1, done: done)
            }
        }
    }

    /// Points the first tab — in any Chrome window, active or not — whose URL
    /// is inside a Shopify admin at that section's URL. Returns the store
    /// handle, or nil when no admin tab is open.
    private static func retargetAdminTab(to section: Section) -> String? {
        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                -- A window with no tabs at all (settings, downloads) throws
                -- instead of looping zero times and would end the search.
                try
                    set tabIndex to 0
                    repeat with t in tabs of w
                        set tabIndex to tabIndex + 1
                        set tabURL to URL of t
                        if (tabURL contains "admin.shopify.com/store/") then
                            set AppleScript's text item delimiters to "admin.shopify.com/store/"
                            set tailText to text item 2 of tabURL
                            set AppleScript's text item delimiters to "/"
                            set handleText to text item 1 of tailText
                            set AppleScript's text item delimiters to "?"
                            set handleText to text item 1 of handleText
                            set AppleScript's text item delimiters to ""
                            if handleText is not "" then
                                set targetURL to "https://admin.shopify.com/store/" & handleText
                                set sectionPath to "\(section.path)"
                                if sectionPath is not "" then set targetURL to targetURL & "/" & sectionPath
                                set URL of t to targetURL
                                set active tab index of w to tabIndex
                                set minimized of w to false
                                set index of w to 1
                                return handleText
                            end if
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return ""
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let handle = result.stringValue ?? ""
        return handle.isEmpty ? nil : handle
    }
}
