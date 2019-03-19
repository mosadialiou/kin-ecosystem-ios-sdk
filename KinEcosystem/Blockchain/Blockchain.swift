//
//  Blockchain.swift
//  KinEcosystem
//
//  Created by Elazar Yifrach on 11/02/2018.
//  Copyright © 2018 Kik Interactive. All rights reserved.
//

import Foundation
import StellarErrors
import KinMigrationModule

struct KinAccountExtraData: Codable {
    var user: String?
    var kinUserId: String?
    var environment: String?
    var onboarded: Bool
    var lastActive: Date
    var backedUp: Bool
}

struct KinImportedAccountData: Decodable{
    let pkey: String
    let seed: String
    let salt: String
}

struct PaymentMemoIdentifier: CustomStringConvertible, Equatable, Hashable {
    var hashValue: Int {
        return description.hashValue
    }

    let version = "1"
    var appId: String
    var id: String

    var description: String {
        return "\(version)-\(appId)-\(id)"
    }

    static func ==(lhs: PaymentMemoIdentifier, rhs: PaymentMemoIdentifier) -> Bool {
        return lhs.description == rhs.description
    }
}

enum BlockchainError: Error {
    case watchNotStarted
    case watchTimedOut
}

enum TimeoutPolicy {
    case fail
    case ignore
}

@available(iOS 9.0, *)
class Blockchain: NSObject {

    fileprivate(set) var account: KinAccountProtocol? {
        didSet {
            if let ac = account {
                if balanceObservers.count > 0 {
                    watchBalance(for: ac)
                }
            } else {
                unwatchBalance()
            }
        }
    }
    private let linkBag = LinkBag()
    private var paymentObservers = [PaymentMemoIdentifier : Observable<String>]()
    private var balanceObservers = [String : (Balance) -> ()]()
    private var paymentsWatcher: PaymentWatchProtocol?
    private var balanceWatcher: BalanceWatchProtocol?
    private var kinAuthToken: AuthToken?
    private var client: KinClientProtocol?
    private var migrationManager: KinMigrationManager?
    private(set) var onboardInFlight = false
    var accountPromise = Promise<KinAccountProtocol>()
    private var isOnboarding: Bool {
        get {
            var result: Bool!
            synced(self) {
                result = onboardInFlight
            }
            return result
        }
        set {
            synced(self) {
                onboardInFlight = newValue
            }
        }
    }
    var isBackedUp: Bool {
        get {
            return account?.kinExtraData.backedUp ?? false
        }
    }
    private var onboardPromise = Promise<Void>()
    private var onboardLock: Int = 1
    private let environment: Environment
    fileprivate(set) var balanceObservable = Observable<Balance>()
    fileprivate(set) var lastBalance: Balance? {
        get {
            guard account != nil else { return nil }
            if  let data = UserDefaults.standard.data(forKey: KinPreferenceKey.lastBalance.rawValue),
                let cachedBalance = try? JSONDecoder().decode(Balance.self, from: data) {
                    return cachedBalance
            }
            return nil
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: KinPreferenceKey.lastBalance.rawValue)
            }
            if let balance = newValue {
                balanceObservable.next(balance)
            } else {
                UserDefaults.standard.set(nil, forKey: KinPreferenceKey.lastBalance.rawValue)
            }
            updateBalanceObservers(newValue ?? Balance(amount: 0))
        }


    }
    fileprivate(set) var onboarded: Bool {
        get {
            var result: Bool!
            synced(onboardLock) {
                result = account?.kinExtraData.onboarded ?? false
            }
            return result
        }
        set {
            isOnboarding = false
            guard newValue else {
                synced(onboardLock) {
                    lastBalance = nil
                    account = nil
                    client = nil
                }
                return
            }
            synced(onboardLock) {
                if  var account = account,
                    let kinUserId = kinAuthToken?.ecosystem_user_id {
                    var kinExtraData = account.kinExtraData
                    kinExtraData.onboarded = true
                    kinExtraData.kinUserId = kinUserId
                    kinExtraData.environment = environment.name
                    kinExtraData.lastActive = Date()
                    account.kinExtraData = kinExtraData
                }
            }
        }
    }

    init(environment: Environment) throws {
        self.environment = environment
    }
    
    func start(with token: AuthToken) throws {
        migrationManager = KinMigrationManager(serviceProvider: try environment.mapToMigrationModuleServiceProvider(), appId: try AppId(token.app_id))
        migrationManager!.delegate = self
        kinAuthToken = token
        accountPromise = Promise<KinAccountProtocol>()
        try migrationManager!.start()
    }
    
    private func startAccount() throws {
        
        try migrateAccountsIfNeeded()
        
        account = try getOrCreateAccount()
        accountPromise.signal(account!)
        _ = balance()
    }
    
    /* account finding pririty:
     
    from same kin users,
        from onboarded
            last active
        else
            last active
        else
            create new
     else
        create new
     
    */
    func getOrCreateAccount() throws -> KinAccountProtocol {
        
        guard let token = kinAuthToken, let client = client else {
            throw KinEcosystemError.service(.notLoggedIn, nil)
        }
        
        var accounts = [KinAccountProtocol]()
        
        // account iteration is currently broken on Accounts
        for i in 0..<client.accounts.count {
            if let anAccount = client.accounts[i] {
                accounts.append(anAccount)
            }
        }
        
        let candidateAccounts = accounts.filter { anAccount in
            return anAccount.kinExtraData.kinUserId == token.ecosystem_user_id
        }
        
        guard candidateAccounts.count > 0 else {
            logVerbose("no accounts found for eco uid \(token.ecosystem_user_id), creating new")
            return try createNewAccount()
        }
        
        let candidateOnboardedAccounts = candidateAccounts.filter ({ anAccount in
            return anAccount.kinExtraData.onboarded
        })
            
        if let candidateOnboardedAccount =  candidateOnboardedAccounts.sorted (by: { accountA, accountB in
                return accountA.kinExtraData.lastActive.compare(accountB.kinExtraData.lastActive) == .orderedAscending
        }).last {
            return candidateOnboardedAccount
        }
        
        if let candidateLastActiveAccount =  candidateAccounts.sorted (by: { accountA, accountB in
            return accountA.kinExtraData.lastActive.compare(accountB.kinExtraData.lastActive) == .orderedAscending
        }).last {
            return candidateLastActiveAccount
        }
        logVerbose("no onboarded or last active accounts found from accounts of eco uid \(token.ecosystem_user_id) with env \(environment.name), creating new")
        return try createNewAccount()
        
    }
    
    func accountForImporting(keystore: String, password: String) throws -> KinAccountProtocol {
        
        guard let token = kinAuthToken, let client = client else {
            throw KinEcosystemError.service(.notLoggedIn, nil)
        }

        guard   let data = keystore.data(using: .utf8),
                let accountData = try? JSONDecoder().decode(KinImportedAccountData.self, from: data) else {
                    
                return try client.importAccount(keystore, passphrase: password)
        }
        
        guard validateAccountPassword(accountData, password: password) else {
            throw KinEcosystemError.blockchain(.invalidPassword, nil)
        }
        
        var accounts = [KinAccountProtocol]()
        
        // account iteration is currently broken on Accounts
        for i in 0..<client.accounts.count {
            if let anAccount = client.accounts[i] {
                accounts.append(anAccount)
            }
        }
        
        let candidateAccounts = accounts.filter { anAccount in
            return  anAccount.kinExtraData.kinUserId == token.ecosystem_user_id &&
                    anAccount.publicAddress == accountData.pkey
        }
        
        guard candidateAccounts.count > 0 else {
            return try client.importAccount(keystore, passphrase: password)
        }
        
        let candidateOnboardedAccounts = candidateAccounts.filter ({ anAccount in
            return anAccount.kinExtraData.onboarded
        })
        
        if let candidateOnboardedAccount =  candidateOnboardedAccounts.sorted (by: { accountA, accountB in
            return accountA.kinExtraData.lastActive.compare(accountB.kinExtraData.lastActive) == .orderedAscending
        }).last {
            return candidateOnboardedAccount
        }
        
        if let candidateLastActiveAccount =  candidateAccounts.sorted (by: { accountA, accountB in
            return accountA.kinExtraData.lastActive.compare(accountB.kinExtraData.lastActive) == .orderedAscending
        }).last {
            return candidateLastActiveAccount
        }
        
        return try client.importAccount(keystore, passphrase: password)
    }
    
    func validateAccountPassword(_ accountData: KinImportedAccountData, password: String) -> Bool {
        
        let eseed = accountData.seed
        let salt = accountData.salt

        guard let newSalt = KeyUtils.salt() else {
             return false
        }

        guard   let skey = try? KeyUtils.keyHash(passphrase: "", salt: newSalt),
                let seed = try? KeyUtils.seed(from: password, encryptedSeed: eseed, salt: salt),
                let _ = KeyUtils.encryptSeed(seed, secretKey: skey) else {
            return false
        }
        
        return true
    }
    
    func setActiveAccount(_ anAccount: KinAccountProtocol) throws {
        guard let token = kinAuthToken else { throw KinEcosystemError.service(.notLoggedIn, nil) }
        account = anAccount
        guard var ac = account else {throw KinEcosystemError.client(.internalInconsistency, nil) }
        var data = ac.kinExtraData
        data.lastActive = Date()
        data.environment = environment.name
        data.kinUserId = token.ecosystem_user_id
        ac.kinExtraData = data
        _ = balance()
    }
    
    func createNewAccount() throws -> KinAccountProtocol {
        guard let token = kinAuthToken, let client = client else { throw KinEcosystemError.service(.notLoggedIn, nil) }
        Kin.track { try StellarAccountCreationRequested() }
        var result = try client.addAccount()
        var kinExtraData = result.kinExtraData
        kinExtraData.kinUserId = token.ecosystem_user_id
        kinExtraData.user = token.user_id
        kinExtraData.environment = environment.name
        result.kinExtraData = kinExtraData
        return result
    }
    
    func migrateAccountsIfNeeded() throws {
        
        guard let token = kinAuthToken, let client = client else { throw KinEcosystemError.service(.notLoggedIn, nil) }
        
        var accounts = [KinAccountProtocol]()
        
        // account iteration is currently broken on Accounts
        for i in 0..<client.accounts.count {
            if let anAccount = client.accounts[i] {
                accounts.append(anAccount)
            }
        }
        
        for var anAccount in accounts.filter ({ anAccount in
            return  anAccount.kinExtraData.user == token.user_id &&
                anAccount.kinExtraData.environment == environment.name &&
                anAccount.kinExtraData.kinUserId == nil
            }) {
                var kinExtraData = anAccount.kinExtraData
                kinExtraData.kinUserId = token.ecosystem_user_id
                anAccount.kinExtraData = kinExtraData
                logVerbose("migrated wallet for \(kinExtraData.user ?? "nil")")
        }
    }
    
    func balance() -> Promise<Decimal> {
        let p = Promise<Decimal>()
        guard let account = account else {
            p.signal(KinEcosystemError.service(.notLoggedIn, nil))
            return p
        }
        account.balance().then { [weak self] kin in
            self?.lastBalance = Balance(amount: kin)
            p.signal(kin)
            }.error { error in
                p.signal(error)
        }
        return p
    }

    func onboard() -> Promise<Void> {
       
        if onboarded {
            return Promise<Void>().signal(())
        }
        
        if isOnboarding {
            return onboardPromise
        }
        
        onboardPromise = Promise<Void>()
        isOnboarding = true
        
        guard let account = account else {
            onboardPromise.signal(KinEcosystemError.service(.notLoggedIn, nil))
            return onboardPromise
        }
        
        balance()
            .then { _ in
                self.onboardPromise.signal(())
                self.onboarded = true
            }
            .error { (bError) in
                if case let KinError.balanceQueryFailed(error) = bError {
                    if let error = error as? StellarError {
                        switch error {
                        case .missingAccount:
                            self.watchAccountCreation(timeout: 15.0)
                                .then {
                                    account.activate()
                                }.then { _ in
                                    Kin.track { try StellarKinTrustlineSetupSucceeded() }
                                    Kin.track { try WalletCreationSucceeded() }
                                    self.onboardPromise.signal(())
                                    self.onboarded = true
                                }.error { error in
                                    Kin.track { try StellarKinTrustlineSetupFailed(errorReason: error.localizedDescription) }
                                    self.onboardPromise.signal(error)
                                    self.onboarded = false
                                }
                            
                        case .missingBalance:
                            account.activate().then { _ in
                                Kin.track { try StellarKinTrustlineSetupSucceeded() }
                                Kin.track { try WalletCreationSucceeded() }
                                self.onboardPromise.signal(())
                                self.onboarded = true
                            }.error { error in
                                Kin.track { try StellarKinTrustlineSetupFailed(errorReason: error.localizedDescription) }
                                self.onboardPromise.signal(error)
                                self.onboarded = false
                            }
                        default:
                            self.onboardPromise.signal(error)
                            self.onboarded = false
                        }
                    }
                    else {
                        self.onboardPromise.signal(bError)
                        self.onboarded = false
                    }
                }
                else {
                    self.onboardPromise.signal(bError)
                    self.onboarded = false
                }
        }

        return onboardPromise
    }
    
    func offboard() {
        onboarded = false
    }


    func pay(to recipient: String, kin: Decimal, memo: String?, whitelist: @escaping WhitelistClosure) -> Promise<TransactionId> {
        guard let account = account else { return Promise<TransactionId>().signal(KinEcosystemError.service(.notLoggedIn, nil)) }
        return account.sendTransaction(to: recipient, kin: kin, memo: memo, fee: 0, whitelist: whitelist)
    }

    func startWatchingForNewPayments(with memo: PaymentMemoIdentifier) throws {
        guard paymentsWatcher == nil else {
            logInfo("payment watcher already started, added watch for \(memo)...")
            paymentObservers[memo] = Observable<String>()
            return
        }
        guard let account = account else { throw KinEcosystemError.service(.notLoggedIn, nil) }
        paymentsWatcher = try account.watchPayments(cursor: "now")
        paymentsWatcher?.emitter.on(next: { [weak self] paymentInfo in
            guard let metadata = paymentInfo.memoText else { return }
            guard let match = self?.paymentObservers.first(where: { (memoKey, _) -> Bool in
                memoKey.description == metadata
            })?.value else { return }
            logInfo("payment found in blockchain for \(metadata)...")
            match.next(paymentInfo.hash)
            match.finish()
        }).add(to: linkBag)
        logInfo("added watch for \(memo)...")
        paymentObservers[memo] = Observable<String>()
    }

    func stopWatchingForNewPayments(with memo: PaymentMemoIdentifier? = nil) {
        guard let memo = memo else {
            paymentObservers.removeAll()
            paymentsWatcher = nil
            logInfo("removed all payment observers")
            return
        }
        paymentObservers.removeValue(forKey: memo)
        if paymentObservers.count == 0 {
            paymentsWatcher = nil
        }
        logInfo("removed payment observer for \(memo)")
    }

    func waitForNewPayment(with memo: PaymentMemoIdentifier, timeout: TimeInterval = 300.0, policy: TimeoutPolicy = .fail) -> Promise<String?> {
        let p = Promise<String?>()
        guard paymentObservers.keys.contains(where: { key -> Bool in
            key == memo
        }) else {
            return p.signal(BlockchainError.watchNotStarted)
        }
        var found = false
        paymentObservers[memo]?.on(next: { [weak self] txHash in
            found = true
            _ = self?.balance()
            p.signal(txHash)
        }).add(to: linkBag)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard found == false else { return }
            guard policy != .ignore else {
                p.signal(nil)
                return
            }
            p.signal(BlockchainError.watchTimedOut)
        }
        return p
    }

    private func updateBalanceObservers(_ balance: Balance? = nil) {
        guard let balance = balance else { return }
        balanceObservers.values.forEach { block in
            block(balance)
        }
    }

    func addBalanceObserver(with block:@escaping (Balance) -> (), identifier: String? = nil) -> String {
        
        let observerIdentifier = identifier ?? UUID().uuidString
        balanceObservers[observerIdentifier] = block
        
        if let balance = lastBalance {
            block(balance)
        }
        
        if let ac = account {
            watchBalance(for: ac)
        }

        return observerIdentifier
    }

    func removeBalanceObserver(with identifier: String) {
        balanceObservers[identifier] = nil
        if balanceObservers.count == 0 {
            unwatchBalance()
        }
    }
    
    private func watchBalance(for account: KinAccountProtocol) {
        if balanceWatcher == nil {
            balanceWatcher = try? account.watchBalance(lastBalance?.amount)
            balanceWatcher?.emitter.on(next: { [weak self] amount in
                self?.lastBalance = Balance(amount: amount)
            }).add(to: linkBag)
        }
    }
    
    private func unwatchBalance() {
        balanceWatcher?.emitter.unlink()
        balanceWatcher = nil
    }
    
    func watchAccountCreation(timeout: TimeInterval = 30.0) -> Promise<Void> {
        
        let p = Promise<Void>()
        guard let account = account else {
            p.signal(KinEcosystemError.service(.notLoggedIn, nil))
            return p
        }
        
        var created = false
        
        do {
            try account.watchCreation()
            .then {
                created = true
                p.signal(())
            }.error { error in
                p.signal(error)
            }
        } catch {
            p.signal(error)
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if created == false {
                p.signal(KinEcosystemError.service(.timeout, nil))
            }
        }

        return p
    }
}



extension KinAccountProtocol {
    
    var kinExtraData: KinAccountExtraData {
        get {
            var result: KinAccountExtraData!
            synced(self) {
                // no data at all - means not onboarded
                guard let extraData = extra else {
                    result = KinAccountExtraData(user: nil, kinUserId: nil, environment: nil, onboarded: false, lastActive: Date.distantPast, backedUp: false)
                    return
                }
                // has valid data, return it
                if let accountData = try? JSONDecoder().decode(KinAccountExtraData.self, from: extraData) {
                    result = accountData
                    return
                }
                // has data, no format. This empty data object was used in previous versions to indicate an onboarded account, presumably single account
                result = KinAccountExtraData(user: nil, kinUserId: nil, environment: nil, onboarded: true, lastActive: Date.distantPast, backedUp: false)
            }
            return result
        }
        mutating set {
            synced(self) {
                extra = try? JSONEncoder().encode(newValue)
            }
        }
    }
    
}

extension KinAccountsProtocol {
    
    var debugInfo: String {
        get {
            var info = "total: \(count)\n\n"
            for i in 0..<count {
                if var anAccount = self[i] {
                    let data = anAccount.kinExtraData
                    info += """
                    account \(i)
                    \(anAccount.publicAddress)
                    ----------------------
                    user        : \(data.user ?? "nil")
                    ecosystem id: \(data.kinUserId ?? "nil")
                    environment : \(data.environment ?? "nil")
                    onboarded   : \(data.onboarded)
                    lastActive  : \(data.lastActive)
                    backedUp    : \(data.backedUp)
                    ----------------------
                    
                    """
                }
            }
            return info
        }
    }
    
}

@available(iOS 9.0, *)
extension Blockchain: KinMigrationManagerDelegate {
    public func kinMigrationManagerNeedsVersion(_ kinMigrationManager: KinMigrationManager) -> Promise<KinVersion> {
        let promise = Promise<KinVersion>()
        promise.signal(.kinCore)
        return promise
    }
    
    public func kinMigrationManagerDidStart(_ kinMigrationManager: KinMigrationManager) {
        //didStartMigration = true
        //migrationDelegate?.kinMigrationDidStart()
    }
    
    public func kinMigrationManager(_ kinMigrationManager: KinMigrationManager, readyWith client: KinClientProtocol) {
        
        self.client = client
        do {
            try startAccount()
        } catch {
            accountPromise.signal(error)
        }
//        if didStartMigration {
//            didStartMigration = false
//            migrationDelegate?.kinMigrationDidFinish()
//        }
        
        //migrationDelegate?.kinMigrationIsReady()
    }
    
    public func kinMigrationManager(_ kinMigrationManager: KinMigrationManager, error: Error) {
        logError(error.localizedDescription)
        accountPromise.signal(error)
        //migrationDelegate?.kinMigration(error: error)
    }
}

@available(iOS 9.0, *)
extension Blockchain: KinMigrationBIDelegate {
    public func kinMigrationMethodStarted() {
        //Kin.track { try MigrationMethodStarted() }
    }
    
    public func kinMigrationCallbackStart() {
        //Kin.track { try MigrationCallbackStart() }
    }
    
    public func kinMigrationCallbackReady(reason: KinMigrationBIReadyReason, version: KinVersion) {
        //Kin.track { try MigrationCallbackReady(sdkVersion: version.mapToKBI, selectedSDKReason: reason.mapToKBI) }
    }
    
    public func kinMigrationCallbackFailed(error: Error) {
        //Kin.track { try MigrationCallbackFailed(errorCode: "", errorMessage: error.localizedDescription, errorReason: "") }
    }
    
    public func kinMigrationVersionCheckStarted() {
        //Kin.track { try MigrationVersionCheckStarted() }
    }
    
    public func kinMigrationVersionCheckSucceeded(version: KinVersion) {
        //Kin.track { try MigrationVersionCheckSucceeded(sdkVersion: version.mapToKBI) }
    }
    
    public func kinMigrationVersionCheckFailed(error: Error) {
        //Kin.track { try MigrationVersionCheckFailed(errorCode: "", errorMessage: error.localizedDescription, errorReason: "") }
    }
    
    public func kinMigrationBurnStarted(publicAddress: String) {
        //Kin.track { try MigrationBurnStarted(publicAddress: publicAddress) }
    }
    
    public func kinMigrationBurnSucceeded(reason: KinMigrationBIBurnReason, publicAddress: String) {
        //Kin.track { try MigrationBurnSucceeded(burnReason: reason.mapToKBI, publicAddress: publicAddress) }
    }
    
    public func kinMigrationBurnFailed(error: Error, publicAddress: String) {
        //Kin.track { try MigrationBurnFailed(errorCode: "", errorMessage: error.localizedDescription, errorReason: "", publicAddress: publicAddress) }
    }
    
    public func kinMigrationRequestAccountMigrationStarted(publicAddress: String) {
        //Kin.track { try MigrationRequestAccountMigrationStarted(publicAddress: publicAddress) }
    }
    
    public func kinMigrationRequestAccountMigrationSucceeded(reason: KinMigrationBIMigrateReason, publicAddress: String) {
        //Kin.track { try MigrationRequestAccountMigrationSucceeded(migrationReason: reason.mapToKBI, publicAddress: publicAddress) }
    }
    
    public func kinMigrationRequestAccountMigrationFailed(error: Error, publicAddress: String) {
        //Kin.track { try MigrationRequestAccountMigrationFailed(errorCode: "", errorMessage: error.localizedDescription, errorReason: "", publicAddress: publicAddress) }
    }
}
