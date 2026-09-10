import Foundation
import UIKit
import SwiftSignalKit

public typealias ListViewTransaction = (@escaping () -> Void) -> Void

public final class ListViewTransactionQueue {
    private var transactions: [ListViewTransaction] = []
    private var isDraining = false
    private var needsDrain = false
    public final var transactionCompleted: () -> Void = { }

    public init() {
    }

    public func addTransaction(_ transaction: @escaping ListViewTransaction) {
        precondition(Thread.isMainThread)
        let beginTransaction = self.transactions.count == 0
        self.transactions.append(transaction)

        if beginTransaction {
            self.drain()
        } else {
            assert(true)
        }
    }

    private func beginNextTransaction() {
        guard let transaction = self.transactions.first else {
            return
        }
        transaction({ [weak self] in
            precondition(Thread.isMainThread)

            if Thread.isMainThread {
                if let strongSelf = self {
                    strongSelf.endTransaction()
                }
            } else {
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        strongSelf.endTransaction()
                    }
                }
            }
        })
    }

    private func drain() {
        precondition(Thread.isMainThread)
        if self.isDraining {
            self.needsDrain = true
            return
        }
        self.isDraining = true
        repeat {
            self.needsDrain = false
            self.beginNextTransaction()
        } while self.needsDrain && !self.transactions.isEmpty
        self.isDraining = false
    }

    private func endTransaction() {
        precondition(Thread.isMainThread)
        Queue.mainQueue().async {
            self.transactionCompleted()
            if !self.transactions.isEmpty {
                let _ = self.transactions.removeFirst()
            }

            if !self.transactions.isEmpty {
                self.drain()
            }
        }
    }
}
