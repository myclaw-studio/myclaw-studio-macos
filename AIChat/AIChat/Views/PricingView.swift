import SwiftUI

// MARK: - Plan data

struct PricingPlan: Identifiable {
    let id: String
    let badge: String
    let name: String
    let price: String
    let priceSub: String
    let planKey: String
    let tokens: String
    let features: [String]
    let isPopular: Bool
}

private var plans: [PricingPlan] {
    [
        PricingPlan(id: "clawbie_only", badge: "🌱", name: L.planClawbieName, price: "$9.9", priceSub: L.planClawbieSub, planKey: "clawbie_only", tokens: L.planClawbieTokens, features: L.planClawbieFeatures, isPopular: false),
        PricingPlan(id: "basic", badge: "⚡", name: L.planBasicName, price: "$12.9", priceSub: "/ mo", planKey: "basic", tokens: L.planBasicTokens, features: L.planBasicFeatures, isPopular: false),
        PricingPlan(id: "pro", badge: "🚀", name: L.planProName, price: "$35", priceSub: "/ mo", planKey: "pro", tokens: L.planProTokens, features: L.planProFeatures, isPopular: true),
        PricingPlan(id: "max", badge: "💎", name: L.planMaxName, price: "$79", priceSub: "/ mo", planKey: "max", tokens: L.planMaxTokens, features: L.planMaxFeatures, isPopular: false),
    ]
}

// MARK: - PricingView

struct PricingView: View {
    var forceMode = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthViewModel
    @State private var isLoading = false
    @State private var isWaitingPayment = false
    @State private var resultMessage: String?
    @State private var isError = false
    @State private var loadingPlanId: String?
    @State private var showCancelConfirm = false
    @State private var showResumeConfirm = false
    @State private var isTogglingSubscription = false

    private static let planRank: [String: Int] = ["free": -1, "clawbie_only": 0, "basic": 1, "pro": 2, "max": 3]

    private func canUpgrade(to plan: PricingPlan) -> Bool {
        let currentRank = Self.planRank[auth.currentPlan] ?? -1
        let targetRank = Self.planRank[plan.planKey] ?? 0
        return targetRank > currentRank
    }

    private func isCurrent(_ plan: PricingPlan) -> Bool {
        return plan.planKey == auth.currentPlan
    }

    private func canSubscribe(_ plan: PricingPlan) -> Bool {
        !isCurrent(plan) && canUpgrade(to: plan)
    }

    private var isAutoRenew: Bool {
        auth.subscriptionStatus == "active"
    }

    private var autoRenewBinding: Binding<Bool> {
        Binding(
            get: { isAutoRenew },
            set: { newValue in
                if newValue {
                    showResumeConfirm = true
                } else {
                    showCancelConfirm = true
                }
            }
        )
    }

    // MARK: - Sub-views (broken out to help Swift type-checker)

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 6) {
            Image("ClawbieLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
            if forceMode {
                Text(L.trialExpired)
                    .font(.title2.bold())
                Text(L.trialExpiredMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(L.choosePlan)
                    .font(.title2.bold())
                Text(L.currentBalance(auth.tokenBalance))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var autoRenewRow: some View {
        if !forceMode && auth.currentPlan != "free" {
            HStack(spacing: 8) {
                if isTogglingSubscription {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: autoRenewBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(auth.isSubscriptionExpired)
                }

                Text(isAutoRenew ? L.autoRenewOn : L.autoRenewOff)
                    .font(.subheadline)
                    .foregroundColor(isAutoRenew ? Color.primary : Color.orange)

                if let days = auth.daysUntilPeriodEnd {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(L.daysLeft(days))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var statusMessageSection: some View {
        if isWaitingPayment {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.paymentRedirect)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
        } else if let msg = resultMessage {
            HStack(spacing: 6) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .red : .green)
                Text(msg)
            }
            .font(.caption)
            .foregroundStyle(isError ? .red : .green)
            .padding(.bottom, 16)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                headerSection

                HStack(alignment: .top, spacing: 16) {
                    ForEach(plans) { plan in
                        PlanCard(
                            plan: plan,
                            isCurrent: isCurrent(plan),
                            canSubscribe: canSubscribe(plan),
                            isLoading: isLoading && loadingPlanId == plan.id,
                            isPaying: isWaitingPayment && loadingPlanId == plan.id,
                            onSubscribe: { subscribe(plan: plan) }
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

                autoRenewRow
                statusMessageSection
            }
            .onChange(of: auth.paymentResult) { _, result in
                guard let result else { return }
                isWaitingPayment = false
                switch result {
                case .success:
                    resultMessage = L.paymentSuccess
                    isError = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        dismiss()
                    }
                case .cancelled:
                    resultMessage = L.paymentIncomplete
                    isError = true
                }
                auth.paymentResult = nil
            }

            if !forceMode {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(16)
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .onAppear {
            Task { await auth.refreshBalance() }
        }
        .alert(L.cancelSubscription, isPresented: $showCancelConfirm) {
            Button(L.confirmCancel, role: .destructive) { toggleAutoRenew(enable: false) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.cancelSubscriptionConfirmMessage)
        }
        .alert(L.resumeSubscription, isPresented: $showResumeConfirm) {
            Button(L.resumeSubscription) { toggleAutoRenew(enable: true) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.resumeConfirmMessage)
        }
    }

    private func toggleAutoRenew(enable: Bool) {
        guard let token = auth.session?.accessToken else {
            resultMessage = L.pleaseSignIn
            isError = true
            return
        }
        isTogglingSubscription = true
        resultMessage = nil

        Task {
            do {
                if enable {
                    try await BackendService().resumeSubscription(accessToken: token)
                } else {
                    try await BackendService().cancelSubscription(accessToken: token)
                }
                await auth.refreshBalance()
                resultMessage = enable ? L.resumeSubscriptionSuccess : L.cancelSubscriptionSuccess
                isError = false
            } catch {
                resultMessage = error.localizedDescription
                isError = true
            }
            isTogglingSubscription = false
        }
    }

    private func subscribe(plan: PricingPlan) {
        guard let token = auth.session?.accessToken else {
            resultMessage = L.pleaseSignIn
            isError = true
            return
        }
        guard canSubscribe(plan), !isLoading, !isWaitingPayment else { return }

        isLoading = true
        resultMessage = nil
        loadingPlanId = plan.id

        Task {
            do {
                let paymentURL: URL
                if AppConfig.usesPaymentBackend {
                    paymentURL = try await BackendService().createSubscription(
                        plan: plan.planKey,
                        accessToken: token
                    )
                } else {
                    paymentURL = try await BackendService().recharge(
                        plan: plan.planKey,
                        accessToken: token
                    )
                }
                NSWorkspace.shared.open(paymentURL)
                isLoading = false
                isWaitingPayment = true
            } catch {
                resultMessage = L.subscriptionFailed(error.localizedDescription)
                isError = true
                isLoading = false
            }
        }
    }
}

// MARK: - PlanCard

private struct PlanCard: View {
    let plan: PricingPlan
    let isCurrent: Bool
    let canSubscribe: Bool
    let isLoading: Bool
    let isPaying: Bool
    let onSubscribe: () -> Void

    private var buttonEnabled: Bool {
        canSubscribe && !isLoading && !isPaying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 6) {
                if plan.isPopular {
                    Text(L.mostPopular)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.clawAccent)
                        .clipShape(Capsule())
                }
                if isCurrent {
                    Text(L.currentBadge)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .frame(minHeight: 25)
            .padding(.bottom, (plan.isPopular || isCurrent) ? 8 : 0)

            HStack(spacing: 8) {
                Text(plan.badge).font(.title2)
                Text(plan.name).font(.headline)
            }
            .padding(.bottom, 14)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(plan.price)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.clawAccent)
                Text(plan.priceSub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            Divider().padding(.bottom, 14)

            Label(plan.tokens, systemImage: "bolt.fill")
                .font(.caption.bold())
                .foregroundStyle(Color.clawAccent)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.features, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.clawAccent)
                            .frame(width: 12, height: 12)
                        Text(feature)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }

            Spacer()

            Button { onSubscribe() } label: {
                Group {
                    if isLoading { ProgressView().controlSize(.small) }
                    else if isPaying { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L.paying).fontWeight(.medium) } }
                    else { Text(L.upgradeBtn).fontWeight(.medium) }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonEnabled ? Color.clawAccent : Color.gray)
            .disabled(!buttonEnabled)
            .padding(.top, 16)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 340)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}
