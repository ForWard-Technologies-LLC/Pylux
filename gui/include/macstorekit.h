// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
#pragma once

#ifdef __cplusplus
#include <QObject>
#include <QStringList>
#include <QVariantList>

class MacStoreKit : public QObject
{
    Q_OBJECT

public:
    explicit MacStoreKit(QObject *parent = nullptr);
    ~MacStoreKit();

    void loadProducts(const QStringList &productIds);
    void purchase(const QString &productId);
    void restorePurchases();
    void checkOwnership();

signals:
    void productsLoaded(const QVariantList &products); // [{id, displayName, blurb, price}, ...]
    void productLoadFailed();
    void purchaseSucceeded(const QString &productId);
    void purchaseCancelled();
    void purchaseFailed(const QString &error);
    void ownershipChecked(bool ownsDonation);
    void restoreFinished(const QString &result); // "none", "alreadyOnDevice", "unavailable"

private:
    void *m_impl; // opaque pointer to ObjC implementation
};

#endif // __cplusplus
