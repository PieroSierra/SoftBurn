//
//  TipJarManager.swift
//  SoftBurn
//
//  Manages In-App Purchase tips using StoreKit 2.
//

import Foundation
import StoreKit
import Combine

@MainActor
final class TipJarManager: ObservableObject {
    static let shared = TipJarManager()
    
    // Product IDs for the three tip tiers
    enum TipTier: String, CaseIterable {
        case espresso = "tip.espresso"
        case latte = "tip.latte"
        case venti = "tip.venti"
        
        var displayName: String {
            switch self {
            case .espresso: return "Espresso"
            case .latte: return "Latte"
            case .venti: return "Venti"
            }
        }
        
        var imageName: String {
            switch self {
            case .espresso: return "coffee_small"
            case .latte: return "coffee_medium"
            case .venti: return "coffee_large"
            }
        }
    }
    
    @Published private(set) var products: [TipTier: Product] = [:]
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var purchasingTier: TipTier?
    
    private var updateListenerTask: Task<Void, Never>?
    
    private init() {
        // Start listening for transaction updates
        updateListenerTask = listenForTransactions()
        
        // Load products on initialization
        Task {
            await loadProducts()
        }
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    /// Loads available products from the App Store
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        
        do {
            let productIdentifiers = TipTier.allCases.map { $0.rawValue }
            let storeProducts = try await Product.products(for: productIdentifiers)
            
            var loadedProducts: [TipTier: Product] = [:]
            for product in storeProducts {
                if let tier = TipTier(rawValue: product.id) {
                    loadedProducts[tier] = product
                }
            }
            
            self.products = loadedProducts
        } catch {
            print("Failed to load products: \(error)")
            // Gracefully handle - products will remain empty
        }
    }
    
    /// Initiates a purchase for the specified tip tier
    func purchase(_ tier: TipTier) async -> Result<Void, Error> {
        guard let product = products[tier] else {
            return .failure(TipJarError.productNotAvailable)
        }
        
        guard purchasingTier == nil else {
            return .failure(TipJarError.purchaseInProgress)
        }
        
        purchasingTier = tier
        defer { purchasingTier = nil }
        
        do {
            let result = try await product.purchase()
            
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                
                // Consumable purchases should be finished immediately
                await transaction.finish()
                
                return .success(())
                
            case .userCancelled:
                return .failure(TipJarError.userCancelled)
                
            case .pending:
                return .failure(TipJarError.pending)
                
            @unknown default:
                return .failure(TipJarError.unknown)
            }
        } catch {
            return .failure(error)
        }
    }
    
    /// Returns the display price for a tip tier, or a placeholder if not loaded
    func price(for tier: TipTier) -> String {
        guard let product = products[tier] else {
            // Return placeholder price based on tier
            switch tier {
            case .espresso: return "£2"
            case .latte: return "£5"
            case .venti: return "£8"
            }
        }
        return product.displayPrice
    }
    
    /// Checks if a product is available for purchase
    func isProductAvailable(_ tier: TipTier) -> Bool {
        return products[tier] != nil
    }
    
    // MARK: - Private Helpers
    
    private func listenForTransactions() -> Task<Void, Never> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try Self.checkVerified(result)
                    // Finish consumable transactions
                    await transaction.finish()
                } catch {
                    // Transaction verification failed - ignore
                    print("Transaction verification failed: \(error)")
                }
            }
        }
    }
    
    private nonisolated static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw TipJarError.unverifiedTransaction
        case .verified(let safe):
            return safe
        }
    }
}

// MARK: - Error Types

enum TipJarError: LocalizedError {
    case productNotAvailable
    case purchaseInProgress
    case userCancelled
    case pending
    case unknown
    case unverifiedTransaction
    
    var errorDescription: String? {
        switch self {
        case .productNotAvailable:
            return "Product not available"
        case .purchaseInProgress:
            return "Purchase already in progress"
        case .userCancelled:
            return "Purchase cancelled"
        case .pending:
            return "Purchase pending"
        case .unknown:
            return "Unknown error"
        case .unverifiedTransaction:
            return "Transaction verification failed"
        }
    }
}
