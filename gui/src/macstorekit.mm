// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "macstorekit.h"

#import <StoreKit/StoreKit.h>
#include <QVariantMap>
#include <QTimer>

static NSString *tierDisplayName(NSString *productID) {
    if ([productID isEqualToString:@"pylux_support_bronze"])   return @"Bronze donation";
    if ([productID isEqualToString:@"pylux_support_silver"])   return @"Silver donation";
    if ([productID isEqualToString:@"pylux_support_gold"])     return @"Gold donation";
    if ([productID isEqualToString:@"pylux_support_platinum"]) return @"Platinum donation";
    return productID;
}

static NSString *tierBlurb(NSString *productID) {
    if ([productID isEqualToString:@"pylux_support_bronze"])   return @"Every donation counts.";
    if ([productID isEqualToString:@"pylux_support_silver"])   return @"A bit more support.";
    if ([productID isEqualToString:@"pylux_support_gold"])     return @"When you want to give more.";
    if ([productID isEqualToString:@"pylux_support_platinum"]) return @"If you want to give the most.";
    return @"Thank you for supporting Pylux.";
}

@interface MacStoreKitImpl : NSObject <SKProductsRequestDelegate, SKPaymentTransactionObserver>
@property (nonatomic, assign) MacStoreKit *qtBridge;
@property (nonatomic, strong) NSArray<NSString *> *orderedProductIds;
@property (nonatomic, strong) NSDictionary<NSString *, SKProduct *> *productMap;
@end

@implementation MacStoreKitImpl

- (instancetype)initWithBridge:(MacStoreKit *)bridge {
    self = [super init];
    if (self) {
        _qtBridge = bridge;
        _productMap = @{};
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
    }
    return self;
}

- (void)dealloc {
    [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
    [super dealloc];
}

- (void)loadProductsWithIds:(NSArray<NSString *> *)productIds {
    self.orderedProductIds = productIds;
    NSSet *idSet = [NSSet setWithArray:productIds];
    SKProductsRequest *request = [[SKProductsRequest alloc] initWithProductIdentifiers:idSet];
    request.delegate = self;
    [request start];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (SKProduct *p in response.products) {
        map[p.productIdentifier] = p;
    }
    self.productMap = map;

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterCurrencyStyle;

    QVariantList products;
    for (NSString *pid in self.orderedProductIds) {
        SKProduct *p = map[pid];
        if (!p) continue;

        formatter.locale = p.priceLocale;
        NSString *priceStr = [formatter stringFromNumber:p.price];

        QVariantMap item;
        item["id"] = QString::fromNSString(p.productIdentifier);
        item["displayName"] = QString::fromNSString(tierDisplayName(p.productIdentifier));
        item["blurb"] = QString::fromNSString(tierBlurb(p.productIdentifier));
        item["price"] = QString::fromNSString(priceStr ?: @"");
        products.append(item);
    }

    QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge, products]() {
        if (products.isEmpty())
            emit bridge->productLoadFailed();
        else
            emit bridge->productsLoaded(products);
    });
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    NSLog(@"[MacStoreKit] SKProductsRequest failed: %@", error.localizedDescription);
    QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge]() {
        emit bridge->productLoadFailed();
    });
}

- (void)purchaseProduct:(NSString *)productId {
    SKProduct *product = self.productMap[productId];
    if (!product) {
        QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge]() {
            emit bridge->purchaseFailed(QStringLiteral("Product not found"));
        });
        return;
    }
    SKPayment *payment = [SKPayment paymentWithProduct:product];
    [[SKPaymentQueue defaultQueue] addPayment:payment];
}

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
    for (SKPaymentTransaction *tx in transactions) {
        switch (tx.transactionState) {
            case SKPaymentTransactionStatePurchased: {
                [[SKPaymentQueue defaultQueue] finishTransaction:tx];
                NSString *pid = tx.payment.productIdentifier;
                QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge, productId = QString::fromNSString(pid)]() {
                    emit bridge->purchaseSucceeded(productId);
                });
                break;
            }
            case SKPaymentTransactionStateFailed: {
                [[SKPaymentQueue defaultQueue] finishTransaction:tx];
                BOOL cancelled = (tx.error.code == SKErrorPaymentCancelled);
                QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge, cancelled]() {
                    if (cancelled)
                        emit bridge->purchaseCancelled();
                    else
                        emit bridge->purchaseFailed(QStringLiteral("Purchase failed"));
                });
                break;
            }
            case SKPaymentTransactionStateRestored: {
                [[SKPaymentQueue defaultQueue] finishTransaction:tx];
                NSString *pid = tx.originalTransaction.payment.productIdentifier ?: tx.payment.productIdentifier;
                QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge, productId = QString::fromNSString(pid)]() {
                    emit bridge->purchaseSucceeded(productId);
                });
                break;
            }
            case SKPaymentTransactionStatePurchasing:
            case SKPaymentTransactionStateDeferred:
                break;
        }
    }
}

- (void)restorePurchases {
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    BOOL found = NO;
    for (SKPaymentTransaction *tx in queue.transactions) {
        if (tx.transactionState == SKPaymentTransactionStateRestored) {
            found = YES;
            break;
        }
    }
    NSString *result = found ? @"alreadyOnDevice" : @"none";
    QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge, r = QString::fromNSString(result)]() {
        emit bridge->restoreFinished(r);
    });
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    Q_UNUSED(error);
    QTimer::singleShot(0, self.qtBridge, [bridge = self.qtBridge]() {
        emit bridge->restoreFinished(QStringLiteral("unavailable"));
    });
}

- (void)checkOwnershipForProductIds:(NSSet<NSString *> *)productIds {
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

@end

// C++ wrapper implementation

MacStoreKit::MacStoreKit(QObject *parent)
    : QObject(parent)
{
    MacStoreKitImpl *impl = [[MacStoreKitImpl alloc] initWithBridge:this];
    m_impl = (void *)impl;
}

MacStoreKit::~MacStoreKit()
{
    MacStoreKitImpl *impl = (MacStoreKitImpl *)m_impl;
    impl.qtBridge = nullptr;
    [impl release];
    m_impl = nullptr;
}

void MacStoreKit::loadProducts(const QStringList &productIds)
{
    MacStoreKitImpl *impl = (MacStoreKitImpl *)m_impl;
    NSMutableArray *ids = [NSMutableArray arrayWithCapacity:productIds.size()];
    for (const QString &id : productIds)
        [ids addObject:id.toNSString()];
    [impl loadProductsWithIds:ids];
}

void MacStoreKit::purchase(const QString &productId)
{
    MacStoreKitImpl *impl = (MacStoreKitImpl *)m_impl;
    [impl purchaseProduct:productId.toNSString()];
}

void MacStoreKit::restorePurchases()
{
    MacStoreKitImpl *impl = (MacStoreKitImpl *)m_impl;
    [impl restorePurchases];
}

void MacStoreKit::checkOwnership()
{
    MacStoreKitImpl *impl = (MacStoreKitImpl *)m_impl;
    NSSet *idSet = [NSSet setWithArray:impl.orderedProductIds ?: @[]];
    [impl checkOwnershipForProductIds:idSet];
}
