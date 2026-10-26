import XCTest
@testable import MyClicky

@MainActor
final class ShopifyActionsTests: XCTestCase {
    func testEverySidebarSectionResolvesByItsDisplayName() {
        let names = ["Home", "Orders", "Drafts", "Shipping labels", "Abandoned checkouts",
                     "Products", "Customers", "Growth", "Discounts", "Content", "Markets",
                     "Finance", "Analytics", "Online Store", "Apps", "Settings"]
        for name in names {
            XCTAssertEqual(ShopifyActions.section(named: name)?.rawValue, name)
        }
    }

    func testSectionNamesIgnoreCaseUnderscoresAndPadding() {
        XCTAssertEqual(ShopifyActions.section(named: " online_store ")?.rawValue, "Online Store")
        XCTAssertEqual(ShopifyActions.section(named: "ORDERS")?.rawValue, "Orders")
        XCTAssertNil(ShopifyActions.section(named: "Themes"))
    }

    func testSectionPathsMatchTheAdminURLs() {
        XCTAssertEqual(ShopifyActions.section(named: "Home")?.path, "")
        XCTAssertEqual(ShopifyActions.section(named: "Orders")?.path, "orders")
        XCTAssertEqual(ShopifyActions.section(named: "Online Store")?.path, "themes")
        XCTAssertEqual(ShopifyActions.section(named: "Settings")?.path, "settings")
    }

    func testOrdersSubSectionsUseTheirOwnAdminPages() {
        XCTAssertEqual(ShopifyActions.section(named: "Drafts")?.path, "draft_orders")
        XCTAssertEqual(ShopifyActions.section(named: "Shipping labels")?.path, "shipping_labels")
        XCTAssertEqual(ShopifyActions.section(named: "Abandoned checkouts")?.path, "checkouts")
    }

    func testEverySidebarSubItemResolvesByItsDisplayName() {
        let names = ["Collections", "Inventory", "Purchase orders", "Transfers", "Gift cards",
                     "Segments", "Companies",
                     "Attribution", "Autopilot", "Campaigns",
                     "Metaobjects", "Files", "Menus", "Blog posts",
                     "Catalogs", "Rollouts",
                     "Credit", "Payouts", "Bill Pay",
                     "Reports", "Live View"]
        for name in names {
            XCTAssertEqual(ShopifyActions.section(named: name)?.rawValue, name)
        }
    }

    /// Multi-segment routes must survive whole for both the admin URL and the
    /// JS route guard — comparing only the last segment would always fail.
    func testMultiSegmentRoutesAreKeptWhole() {
        XCTAssertEqual(ShopifyActions.section(named: "Inventory")?.path, "products/inventory")
        XCTAssertEqual(ShopifyActions.section(named: "Segments")?.path, "customers/segments")
        XCTAssertEqual(ShopifyActions.section(named: "Attribution")?.path, "growth/attribution")
        XCTAssertEqual(ShopifyActions.section(named: "Autopilot")?.path, "growth/autopilot")
        XCTAssertEqual(ShopifyActions.section(named: "Campaigns")?.path, "growth/campaigns")
        XCTAssertEqual(ShopifyActions.section(named: "Content")?.path, "content/metaobjects")
        XCTAssertEqual(ShopifyActions.section(named: "Metaobjects")?.path, "content/metaobjects")
        XCTAssertEqual(ShopifyActions.section(named: "Blog posts")?.path, "content/articles")
        XCTAssertEqual(ShopifyActions.section(named: "Finance")?.path, "payments/payouts")
        XCTAssertEqual(ShopifyActions.section(named: "Payouts")?.path, "payments/payouts")
        XCTAssertEqual(ShopifyActions.section(named: "Bill Pay")?.path, "finance/billpay")
        XCTAssertEqual(ShopifyActions.section(named: "Reports")?.path, "analytics/reports")
        XCTAssertEqual(ShopifyActions.section(named: "Live View")?.path, "analytics/live")
    }

    func testStoreHandleIsReadFromAnyAdminPage() {
        XCTAssertEqual(ShopifyActions.storeHandle(from: "https://admin.shopify.com/store/purrified-air/orders"), "purrified-air")
        XCTAssertEqual(ShopifyActions.storeHandle(from: "https://admin.shopify.com/store/purrified-air"), "purrified-air")
        XCTAssertEqual(ShopifyActions.storeHandle(from: "https://admin.shopify.com/store/purrified-air?embedded=1"), "purrified-air")
    }

    func testStoreHandleRejectsNonAdminURLs() {
        XCTAssertNil(ShopifyActions.storeHandle(from: "https://purrifiedair.com/products"))
        XCTAssertNil(ShopifyActions.storeHandle(from: "https://admin.shopify.com/store/"))
        XCTAssertNil(ShopifyActions.storeHandle(from: "not a url"))
    }
}
