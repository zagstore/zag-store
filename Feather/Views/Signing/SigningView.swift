//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options
	private let _certificateDefaults: Options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	@ObservedObject private var _accountPairing = ZagRPPairingCore.shared
	@State private var _signingMethod: ZagSigningMethod = .importedCertificate
	@State private var _appleIDOptions = OptionsManager.shared.appleIDSigningDefaults
	@State private var _useOnlyAppleIDOptions = false
	private var _certificateChanges: [String] {
		_temporaryOptions.certificateCustomisations(since: _certificateDefaults,
			identifier: app.identifier, name: app.name, hasIcon: appIcon != nil)
	}
	@State private var _accountInstallMessage: String?
	@State private var _certificateIssue: ZagNativeAccountInstall.CertificateIssue?
	@State private var _nativeProgress: ZagNativeSigningProgress?
	@State private var _accountDiagnostics = ""
	@State private var _sourceImportID: String?
	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)])
	private var _originalImports: FetchedResults<Imported>
	private var _renewing: ZagNativeAppInventory.Entry? { ZagNativeAppInventory.entry(app) }
	private var _matchingImports: [Imported] {
		guard let original = _renewing?.installation.record.originalBundleIdentifier else { return [] }
		return _originalImports.filter { $0.identifier == original }
	}
	#endif
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State var appIcon: UIImage?
    @State private var _originalEntitlementAudit: ZagOriginalEntitlementAudit.Report?
    @State private var _originalEntitlementRunning = false
    @State private var _originalEntitlementRequest = UUID()
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	init(app: AppInfoPresentable) {
		self.app = app
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		if ZagNativeAppInventory.entry(app) != nil || ZagCertificateSelection.preference == .appleAccount {
			__signingMethod = State(initialValue: .freeAppleAccount)
		}
		#endif
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
		var certificate = OptionsManager.shared.options
		if certificate.ppqProtection, let identifier = app.identifier, ZagCertificateSelection.activeCertificate()?.ppQCheck == true {
			certificate.appIdentifier = "\(identifier).\(certificate.ppqString)"
		}
		if let id = app.identifier, let mapped = certificate.identifiers[id] { certificate.appIdentifier = mapped }
		if let name = app.name, let mapped = certificate.displayNames[name] { certificate.appName = mapped }
		_certificateDefaults = certificate
		__temporaryOptions = State(initialValue: certificate)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView("Customise App", displayMode: .inline) {
			Form {
				#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
				if _renewing == nil {
					Picker("Signing Method", selection: $_signingMethod) {
						Text(ZagSigningMethod.importedCertificate.title).tag(ZagSigningMethod.importedCertificate)
						Text(ZagSigningMethod.freeAppleAccount.title).tag(ZagSigningMethod.freeAppleAccount)
					}
				}
				if _signingMethod == .freeAppleAccount {
					if _renewing == nil, !ZagNativeAccountInstall.hasSession {
						NavigationLink("Add Apple ID") { ZagAppleSigningSettingsView() }
					} else if !_accountPairing.hasSavedPairing {
						Text("Pair this iPhone in Settings to install apps.").foregroundStyle(.secondary)
					} else if _accountPairing.pairedIdentity == nil {
						Text("Zag Store will identify this iPhone using its saved pairing when you start.").foregroundStyle(.secondary)
					}
					if let entry = _renewing {
						if let scope = entry.installation.record.owner?.scope,
						   !ZagNativeAccountInstall.hasConnectedAccount(scope.accountID),
						   let owner = try? ZagNativeAppleIDs.shared.accountForAuthentication(scope.accountID) {
							NavigationLink("Sign in with the Apple ID that signed this app") {
								ZagAppleIDAuthenticationView(account: owner, requiresOriginalAccount: true)
							}
						}
						if !ZagNativeAppInventory.hasSource(entry) {
							Text(ZagNativeAppInventory.Failure.missingSource.localizedDescription)
								.font(.footnote).foregroundStyle(.secondary)
							Picker("Original App", selection: $_sourceImportID) {
								Text("Select Import").tag(nil as String?)
								ForEach(_matchingImports) { imported in
									Text(imported.name ?? "App").tag(imported.uuid)
								}
							}
						}
					} else {
						Toggle("Install After Signing", isOn: $_appleIDOptions.installAfterSigning)
						Toggle("Delete Imported App After Signing", isOn: $_appleIDOptions.deleteImportAfterSigning)
						if !_certificateChanges.isEmpty {
							Text(ZagNativeAccountInstall.Failure.unsupportedOptions(_certificateChanges).localizedDescription)
								.font(.footnote).foregroundStyle(.orange)
							Toggle("Use only Apple ID options for this signing", isOn: $_useOnlyAppleIDOptions)
						}
					}
					if let progress = _nativeProgress {
						VStack(spacing: 12) {
							InstallProgressView(app: app, progress: progress.fraction, completed: progress == .verified)
								.foregroundStyle(.tint)
							Text(progress.title)
								.font(.footnote.weight(.medium))
								.contentTransition(.numericText())
						}
						.frame(maxWidth: .infinity)
						.accessibilityElement(children: .combine)
						.accessibilityValue(progress.title)
					}
					if let issue = _certificateIssue, ZagNativeAccountInstall.hasConnectedAccount(issue.scope.accountID) {
						Section("Development Certificate") {
							Text(issue.failure.message).font(.footnote)
							Button("Copy Diagnostics") { UIPasteboard.general.string = ZagSigningDiagnostics.latest }
							if let recovery = issue.recovery {
								NavigationLink("Recover Certificate Request") {
									ZagCertificateRecoveryView(model: recovery, teamName: issue.teamName, onResolved: { _startAccountInstall(resuming: issue.scope) })
								}
							}
							NavigationLink("Manage Development Certificates") {
								ZagCertificateReplacementView(model: .inventory(team: issue.scope.teamID, expectedScope: issue.scope), onRevoked: { _startAccountInstall(resuming: issue.scope) })
							}
							Text("Signing continues after the certificate request is resolved.")
								.font(.footnote).foregroundStyle(.secondary)
						}
					}
				} else {
					_certificateOptions
				}
				#else
				_certificateOptions
				#endif
				
				// horrible
				Rectangle()
					.foregroundStyle(.clear)
					.frame(height: 30)
					.listRowBackground(EmptyView())
			}
			.overlay {
				VStack(spacing: 0) {
					Spacer()
					NBVariableBlurView()
						.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
						.rotationEffect(.degrees(180))
						.overlay {
							Button {
								_start()
							} label: {
								NBSheetButton(title: _signButtonTitle, style: .prominent)
									.padding()
							}
							.buttonStyle(.plain)
							.disabled(!_canStartSigning)
							.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
						}
				}
				.ignoresSafeArea(edges: .bottom)
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Reset") {
                        #if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
                        if _signingMethod == .freeAppleAccount {
                            _appleIDOptions = OptionsManager.shared.appleIDSigningDefaults
                            _useOnlyAppleIDOptions = false
                            return
                        }
                        #endif
                        _temporaryOptions = _certificateDefaults
                        appIcon = nil
                    }
                    .accessibilityLabel("Reset Signing Options")

                    Button { _closeSigning() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Customise App")
                }
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
		}
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		.alert("Apple Account Installation", isPresented: Binding(
			get: { _accountInstallMessage != nil },
			set: { if !$0 { _accountInstallMessage = nil } }
		)) {
			if !_accountDiagnostics.isEmpty {
				Button("Copy Diagnostics") { UIPasteboard.general.string = _accountDiagnostics }
			}
			Button("OK", role: .cancel) { _accountInstallMessage = nil }
		} message: {
			Text(_accountInstallMessage ?? "")
		}
		.interactiveDismissDisabled(_isSigning && _signingMethod == .freeAppleAccount)
		.onChange(of: _temporaryOptions) { _ in _useOnlyAppleIDOptions = false }
		.onChange(of: appIcon != nil) { _ in _useOnlyAppleIDOptions = false }
		#endif
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		Section {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					FRAppIconView(app: app, size: 56)
				}
			}
			
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			}
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		} header: {
            Text("Customisation")
        }
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		Section {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		} header: {
            Text(.localized("Signing"))
        }
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		Section {
            NavigationLink {
                SigningModifyView(app: app, options: $_temporaryOptions)
            } label: {
                Text(.localized("Modify"))
            }
            /* Previously a DisclosureGroup; use a navigation row so the
               chevron matches Properties and other navigation links. */
            /*
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				#if NIGHTLY || DEBUG
					NavigationLink(.localized("Entitlements") + " (BETA)") {
						SigningEntitlementsView(
							bindingValue: $_temporaryOptions.appEntitlementsFile
						)
					}
				#endif
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				}
			}
			
            */
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.navigationTitle(.localized("Properties"))
			}
		} header: {
            Text(.localized("Advanced"))
        }
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Signing modifications
private struct SigningModifyView: View {
    let app: AppInfoPresentable
    @Binding var options: Options

    var body: some View {
        Form {
            Section {
                NavigationLink(.localized("Existing Dylibs")) {
                    SigningDylibView(app: app, options: $options.optional())
                }
                NavigationLink(.localized("Frameworks & PlugIns")) {
                    SigningFrameworksView(app: app, options: $options.optional())
                }
                #if NIGHTLY || DEBUG
                NavigationLink(.localized("Entitlements") + " (BETA)") {
                    SigningEntitlementsView(bindingValue: $options.appEntitlementsFile)
                }
                #endif
                NavigationLink(.localized("Tweaks")) {
                    SigningTweaksView(options: $options)
                }
            }
        }
        .navigationTitle(.localized("Modify"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Signing preflight (local, non-blocking advisory)
extension SigningView {
    @ViewBuilder
    private func _signingPreflightSection() -> some View {
        if _temporaryOptions.signingOption == .default {
            Section {
                if let certificate = _selectedCert() {
                    NavigationLink {
                        ZagSigningPreflightView(
                            app: app,
                            certificate: certificate,
                            options: _temporaryOptions,
                            onClose: { dismiss() }
                        )
                    } label: {
                        Label("Signing Preflight", systemImage: "checkmark.shield")
                    }
                    NavigationLink {
                        ZagSigningAuditView(
                            app: app,
                            certificate: certificate,
                            options: _temporaryOptions
                        )
                    } label: {
                        Label("Full Local Signing Audit", systemImage: "checkmark.shield.fill")
                    }
                } else {
                    Label("Choose a certificate to inspect signing compatibility", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Read-only preflight and on-demand signing audit. The signing engine is unchanged.")
            }
        }
    }
}

// MARK: - Signing preflight (local, non-blocking advisory)
struct ZagSigningPreflightView: View {
    @Environment(\.dismiss) private var dismiss
    let app: AppInfoPresentable
    let certificate: CertificatePair
    let options: Options
    let onClose: () -> Void
    @State private var originalEntitlementAudit: ZagOriginalEntitlementAudit.Report?
    @State private var originalEntitlementRunning = false
    @State private var originalEntitlementRequest = UUID()

    var body: some View {
        Form {
            _preflightSummary()
            _certificateSection()
            _identifierSection()
            _entitlementsSection()
        }
        .navigationTitle("Signing Preflight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close Signing and Return to Apps")
            }
        }
    }

    @ViewBuilder
    private func _certificateSection() -> some View {
        Section {
            if let profile = Storage.shared.getProvisionFileDecoded(for: certificate) {
                LabeledContent("Profile", value: profile.Name)
                _preflightRow(
                    "P12 File",
                    okay: Storage.shared.getFile(.certificate, from: certificate) != nil,
                    success: "Present",
                    failure: "Missing"
                )
                _preflightRow(
                    "Profile Dates",
                    okay: profile.CreationDate <= Date() && profile.ExpirationDate > Date(),
                    success: "Current",
                    failure: "Not valid"
                )
                if certificate.revoked {
                    Label("Previously marked revoked", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                }
                NavigationLink("Certificate Details") {
                    CertificatesInfoView(cert: certificate)
                }
            } else {
                Label("Provisioning profile unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.orange)
            }
        } header: {
            Text("Certificate")
        }
    }

    @ViewBuilder
    private func _identifierSection() -> some View {
        if let profile = Storage.shared.getProvisionFileDecoded(for: certificate) {
            let bundleID = options.appIdentifier ?? app.identifier ?? ""
            let appID = profile.Entitlements?["application-identifier"]?.value as? String
                ?? profile.Entitlements?["com.apple.application-identifier"]?.value as? String
            Section {
                _identifierPreflight(
                    originalID: app.identifier ?? "",
                    requestedID: bundleID,
                    profileAppID: appID,
                    matches: _profileAllows(bundleID, appID: appID, teamIDs: profile.TeamIdentifier),
                    ppqMayChange: options.ppqProtection && certificate.ppQCheck
                )
            } header: {
                Text("App Identifier")
            }
        }
    }

    @ViewBuilder
    private func _entitlementsSection() -> some View {
        if let profile = Storage.shared.getProvisionFileDecoded(for: certificate) {
            Section {
                if let entitlementsURL = options.appEntitlementsFile {
                    if let issues = _preflightEntitlementIssues(at: entitlementsURL, profile: profile) {
                        if issues.isEmpty {
                            Label("Custom entitlements: no basic differences found", systemImage: "checkmark.circle")
                                .foregroundStyle(Color.green)
                        } else {
                            DisclosureGroup("Custom entitlements to review (\(issues.count))") {
                                ForEach(issues, id: \.self) { issue in
                                    Text(issue)
                                        .font(.caption)
                                }
                            }
                        }
                    } else {
                        Label("Custom entitlements could not be read", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                    }
                } else {
                    LabeledContent("Custom Entitlements", value: "Not selected")
                }
                _originalEntitlementInspection(profile: profile)
            } header: {
                Text("Entitlements")
            } footer: {
                Text("Original-app capabilities may be replaced when signing. Differences here are advisory, not confirmed failures.")
            }
        }
    }

    // A conservative summary of checks performed locally. This does not
    // predict installation success or override the signer's own behaviour.
    @ViewBuilder
    private func _preflightSummary() -> some View {
        Section {
            if let profile = Storage.shared.getProvisionFileDecoded(for: certificate) {
                let hasP12 = Storage.shared.getFile(.certificate, from: certificate) != nil
                let datesCurrent = profile.CreationDate <= Date() && profile.ExpirationDate > Date()
                let customIssues: [String]? = options.appEntitlementsFile.flatMap {
                    _preflightEntitlementIssues(at: $0, profile: profile)
                }
                let customUnreadable = options.appEntitlementsFile != nil && customIssues == nil
                let customWarnings = customIssues?.count ?? 0
                let needsAttention = !hasP12 || !datesCurrent || certificate.revoked || customUnreadable || customWarnings > 0
                let message = needsAttention
                    ? "Some local checks need attention"
                    : "No issues in the basic local checks"
                Label(message, systemImage: needsAttention ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(needsAttention ? Color.orange : Color.green)

                if !hasP12 {
                    _summaryFinding("P12 file is missing")
                }
                if !datesCurrent {
                    _summaryFinding("Provisioning profile is not currently valid")
                }
                if certificate.revoked {
                    _summaryFinding("Certificate was previously marked revoked")
                }
                if customUnreadable {
                    _summaryFinding("Selected custom entitlements could not be read")
                } else if customWarnings > 0 {
                    _summaryFinding("\(customWarnings) potential custom entitlement difference(s)")
                }
                Text("The summary covers local files, profile dates and any explicitly selected custom entitlements. Identifier and original-app comparisons are advisory, not confirmed signing errors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Cannot assess: provisioning profile unavailable", systemImage: "questionmark.circle")
                    .foregroundStyle(Color.orange)
            }
            DisclosureGroup("Not Verified") {
                ForEach([
                    "P12 password and private-key usability",
                    "Live Apple certificate revocation status",
                    "Final signed bundle identifier and entitlements",
                    "Device registration and installation eligibility",
                    "Nested app and extension signing outcomes"
                ], id: \.self) { item in
                    Label(item, systemImage: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Pre-signing Summary")
        } footer: {
            Text("Informational only. These checks never prevent signing.")
        }
    }

    private func _summaryFinding(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func _identifierPreflight(
        originalID: String,
        requestedID: String,
        profileAppID: String?,
        matches: Bool,
        ppqMayChange: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: matches && !ppqMayChange ? "checkmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(matches && !ppqMayChange ? Color.green : Color.secondary)
            Text("App Identifier")
            Spacer(minLength: 8)
            Text(matches && !ppqMayChange ? "Pattern matches" : "Not verified")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        if !matches || ppqMayChange {
            Text("The final signed identifier is not verified. This does not establish a certificate failure.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        DisclosureGroup("Compare Identifiers") {
            LabeledContent("Original App") {
                Text(originalID.isEmpty ? "Unavailable" : originalID)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Requested") {
                Text(requestedID.isEmpty ? "Unavailable" : requestedID)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Profile App ID") {
                Text(profileAppID ?? "Unavailable")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if ppqMayChange {
                Text("PPQ protection can override the requested identifier at signing time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Comparison uses the current signing options and selected profile. It does not inspect a finished signed IPA.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func _originalEntitlementInspection(profile: Certificate) -> some View {
        Button {
            _inspectOriginalEntitlements(profile: profile)
        } label: {
            HStack(spacing: 8) {
                if originalEntitlementRunning {
                    ProgressView()
                } else {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                Text("Inspect Original Entitlements")
            }
        }
        .disabled(originalEntitlementRunning)

        if let report = originalEntitlementAudit {
            VStack(alignment: .leading, spacing: 5) {
                Label(report.title, systemImage: report.error != nil
                      ? "questionmark.circle" : "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(report.error != nil ? Color.orange : Color.secondary)
                Text(report.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !report.issues.isEmpty {
                DisclosureGroup("Original capabilities to review (\(report.issues.count))") {
                    ForEach(report.issues, id: \.self) { issue in
                        Text(issue)
                            .font(.caption)
                    }
                }
            }
            if !report.identityKeys.isEmpty {
                DisclosureGroup("Identity-bound keys (\(report.identityKeys.count))") {
                    ForEach(report.identityKeys, id: \.self) { key in
                        Text(key)
                            .font(.caption)
                    }
                    Text("These values may change during re-signing; the original values are not treated as final signing conflicts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func _inspectOriginalEntitlements(profile: Certificate) {
        guard !originalEntitlementRunning else { return }
        guard let appURL = Storage.shared.getAppDirectory(for: app),
              let executable = Bundle(url: appURL)?.executableURL else {
            originalEntitlementAudit = .init(
                inspected: 0, issues: [], identityKeys: [],
                error: "The imported application's executable is unavailable."
            )
            return
        }

        // Capture immutable property-list bytes instead of moving Core Data
        // objects or non-Sendable dictionaries into the detached task.
        let profileValues = profile.Entitlements?.mapValues { $0.value } ?? [:]
        guard PropertyListSerialization.propertyList(profileValues, isValidFor: .xml),
              let profileData = try? PropertyListSerialization.data(
                fromPropertyList: profileValues, format: .xml, options: 0
              ) else {
            originalEntitlementAudit = .init(
                inspected: 0, issues: [], identityKeys: [],
                error: "The selected profile's entitlements could not be decoded."
            )
            return
        }

        let request = UUID()
        originalEntitlementRequest = request
        originalEntitlementRunning = true
        originalEntitlementAudit = nil
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                ZagOriginalEntitlementAudit.inspect(executable: executable, profileData: profileData)
            }.value
            guard originalEntitlementRequest == request else { return }
            originalEntitlementAudit = report
            originalEntitlementRunning = false
        }
    }

    private func _preflightRow(_ title: String, okay: Bool, success: String, failure: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: okay ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(okay ? Color.green : Color.orange)
            Text(title)
            Spacer(minLength: 8)
            Text(okay ? success : failure)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    private func _profileAllows(_ bundleID: String, appID: String?, teamIDs: [String]) -> Bool {
        guard !bundleID.isEmpty,
              let appID,
              let separator = appID.firstIndex(of: ".") else { return false }
        let prefix = String(appID[..<separator])
        guard teamIDs.contains(prefix) else { return false }
        let pattern = String(appID[appID.index(after: separator)...])
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") && pattern.filter({ $0 == "*" }).count == 1 {
            let start = String(pattern.dropLast())
            return bundleID.hasPrefix(start) && bundleID.count > start.count
        }
        return bundleID == pattern
    }

    // This compares an explicitly selected entitlement plist, not the
    // entitlements extracted from the imported IPA's code signature.
    private func _preflightEntitlementIssues(at url: URL, profile: Certificate) -> [String]? {
        guard let bytes = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil),
              let requested = raw as? [String: Any],
              let allowed = profile.Entitlements else { return nil }

        var issues: [String] = []
        for key in requested.keys.sorted() {
            guard let requestedValue = requested[key] else { continue }
            guard let profileValue = allowed[key]?.value else {
                issues.append("\(key): not included in profile")
                continue
            }
            if !_preflightValueMatches(requestedValue, allowed: profileValue) {
                issues.append("\(key): requested value differs from profile")
            }
        }
        return issues
    }

    private func _preflightValueMatches(_ requested: Any, allowed: Any) -> Bool {
        if let requested = requested as? String, let allowed = allowed as? String {
            if requested == allowed { return true }
            if allowed.hasSuffix("*") && allowed.filter({ $0 == "*" }).count == 1 {
                return requested.hasPrefix(String(allowed.dropLast()))
            }
            return false
        }
        if let requested = requested as? [String], let allowed = allowed as? [String] {
            return requested.allSatisfy { item in
                allowed.contains { _preflightValueMatches(item, allowed: $0) }
            }
        }
        if let requested = requested as? [String: Any], let allowed = allowed as? [String: Any] {
            return requested.allSatisfy { key, value in
                guard let permitted = allowed[key] else { return false }
                return _preflightValueMatches(value, allowed: permitted)
            }
        }
        if let requested = requested as? NSNumber, let allowed = allowed as? NSNumber {
            return CFGetTypeID(requested) == CFGetTypeID(allowed) && requested == allowed
        }
        if let requested = requested as? Data, let allowed = allowed as? Data {
            return requested == allowed
        }
        return false
    }
}

// MARK: - Original code-signature entitlement audit
// Reports only capabilities present in the existing main executable.
// Does not claim to know the entitlements the signer will finally generate.
private enum ZagOriginalEntitlementAudit {
    struct Report: Sendable {
        let inspected: Int
        let issues: [String]
        let identityKeys: [String]
        let error: String?

        var title: String {
            if error != nil { return "Original signature not inspected" }
            return issues.isEmpty ? "Original capabilities inspected" : "Original capabilities need review"
        }
        var summary: String {
            if let error { return error }
            return "\(inspected) original entitlement(s), \(issues.count) profile difference(s). Not a final signing check."
        }
    }

    static func inspect(executable: URL, profileData: Data) -> Report {
        let original: [String: Any]
        do {
            original = try ZagMachOSignatureInspector.entitlements(at: executable)
        } catch ZagMachOSignatureInspector.InspectionError.unsupportedFormat {
            return Report(inspected: 0, issues: [], identityKeys: [],
                          error: "This Mach-O format is not supported by the current signature inspector (for example, a fat binary).")
        } catch ZagMachOSignatureInspector.InspectionError.missingEntitlements {
            return Report(inspected: 0, issues: [], identityKeys: [],
                          error: "No XML entitlements were found in the original executable's signature.")
        } catch {
            return Report(inspected: 0, issues: [], identityKeys: [],
                          error: "Unable to inspect the original executable's code-signature entitlements.")
        }
        guard let profile = (try? PropertyListSerialization.propertyList(
            from: profileData, options: [], format: nil
        )) as? [String: Any] else {
            return Report(inspected: original.count, issues: [], identityKeys: [],
                          error: "The selected provisioning profile's entitlements are unreadable.")
        }

        // Original app and team identifiers commonly change on re-signing.
        let identityKeys: Set<String> = [
            "application-identifier",
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "com.apple.security.application-groups",
            "com.apple.developer.ubiquity-kvstore-identifier",
            "com.apple.developer.icloud-container-identifiers",
            "get-task-allow"
        ]
        let ignored = original.keys.filter { identityKeys.contains($0) }.sorted()
        var issues: [String] = []
        for key in original.keys.sorted() where !identityKeys.contains(key) {
            guard let value = original[key] else { continue }
            guard let permitted = profile[key] else {
                issues.append("\(key): present in original app, absent from selected profile")
                continue
            }
            if !matches(value, permitted) {
                issues.append("\(key): original value differs from selected profile")
            }
        }
        return Report(inspected: original.count, issues: issues, identityKeys: ignored, error: nil)
    }

    private static func matches(_ original: Any, _ allowed: Any) -> Bool {
        if let lhs = original as? String, let rhs = allowed as? String {
            if lhs == rhs { return true }
            if rhs.hasSuffix("*"), rhs.filter({ $0 == "*" }).count == 1 {
                return lhs.hasPrefix(String(rhs.dropLast()))
            }
            return false
        }
        if let lhs = original as? [String], let rhs = allowed as? [String] {
            return lhs.allSatisfy { item in rhs.contains { matches(item, $0) } }
        }
        if let lhs = original as? [String: Any], let rhs = allowed as? [String: Any] {
            return lhs.allSatisfy { key, value in
                guard let permitted = rhs[key] else { return false }
                return matches(value, permitted)
            }
        }
        if let lhs = original as? NSNumber, let rhs = allowed as? NSNumber {
            return CFGetTypeID(lhs) == CFGetTypeID(rhs) && lhs == rhs
        }
        if let lhs = original as? Data, let rhs = allowed as? Data {
            return lhs == rhs
        }
        return false
    }
}

// MARK: - Extension: View (import)
extension SigningView {
	private var _signButtonTitle: String {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		if _signingMethod == .freeAppleAccount {
			if _isSigning { return _nativeProgress?.title ?? "Preparing App" }
			if _renewing != nil { return "Resign and Install" }
			if let issue = _certificateIssue, ZagNativeAccountInstall.hasConnectedAccount(issue.scope.accountID) {
				return "Resume Sign and Install"
			}
			return _appleIDOptions.installAfterSigning ? "Sign and Install" : "Sign"
		}
		#endif
		return .localized("Start Signing")
	}

	private var _canStartSigning: Bool {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		if _signingMethod == .freeAppleAccount {
			guard _accountPairing.hasSavedPairing && !_isSigning else { return false }
			if let entry = _renewing {
				guard entry.installation.record.owner != nil else { return false }
				return ZagNativeAppInventory.hasSource(entry) || _sourceImportID != nil
			}
			return _useOnlyAppleIDOptions || _certificateChanges.isEmpty
		}
		#endif
		return true
	}

	@ViewBuilder
	private var _certificateOptions: some View {
		_customizationOptions(for: app)
		_cert()
		_signingPreflightSection()
		_customizationProperties(for: app)
	}

	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	private func _startAccountInstall(resuming scope: ZagSigningScope? = nil) {
		guard !_isSigning else { return }
		if let issue = _certificateIssue, !ZagNativeAccountInstall.hasConnectedAccount(issue.scope.accountID) { _certificateIssue = nil }
		let expectedScope = scope ?? _certificateIssue?.scope
		_isSigning = true
		_accountDiagnostics = ""
		_nativeProgress = .preparing
		Task { @MainActor in
			defer { _isSigning = false }
			do {
				if let entry = _renewing {
					try await _renew(entry)
				} else {
					try ZagNativeAccountInstall.validateOptions(explicitCertificateChanges: _useOnlyAppleIDOptions ? [] : _certificateChanges)
					guard let source = Storage.shared.getAppDirectory(for: app) else { throw ZagNativeAccountInstall.Failure.invalidApp }
					let accountID = try await ZagAppleIDSigningSelection.resolve(required: expectedScope?.accountID)
					let result = try await ZagNativeAccountInstall.install(
						source: source, name: app.name ?? "App", accountID: accountID, expectedScope: expectedScope,
						installAfterSigning: _appleIDOptions.installAfterSigning,
						onCertificateReady: { @MainActor in _certificateIssue = nil }, progress: _reportNativeProgress
					)
					switch result {
					case .verified, .signedOnly:
						if _appleIDOptions.deleteImportAfterSigning, !app.isSigned { Storage.shared.deleteApp(for: app) }
					default: throw ZagNativeAppInventory.Failure.unverified
					}
					if case .signedOnly = result {
						_certificateIssue = nil
						_nativeProgress = nil
						_accountInstallMessage = "Signed and saved in Apps. Tap Install when you’re ready."
						return
					}
				}
				_certificateIssue = nil
				_accountInstallMessage = "Installed and verified on this iPhone. Open the app from the Home Screen."
			} catch is ZagInstallCancelled {
				_nativeProgress = nil
			} catch let issue as ZagNativeAccountInstall.CertificateIssue {
				_nativeProgress = nil
				_certificateIssue = issue
			} catch {
				_nativeProgress = nil
				let phase = ZagNativeAccountInstall.failurePhase(error, fallback: _renewing == nil ? .signing : .refresh)
				_accountDiagnostics = [ZagSigningDiagnostics.latest, ZagSigningDiagnostics.failureDetails(phase, error)].joined(separator: "\n")
				if ZagFreeAppLimitReached.classify(error) != nil {
					ZagNativeAccountInstall.showInlineFailure(error, fallback: phase)
				} else {
					_accountInstallMessage = phase.message
				}
			}
		}
	}

	private func _renew(_ entry: ZagNativeAppInventory.Entry) async throws {
		guard let scope = entry.installation.record.owner?.scope else {
			throw ZagNativeAppInventory.Failure.wrongAccount
		}
		let accountID = try await ZagAppleIDSigningSelection.resolve(required: scope.accountID)
		func renew(_ source: URL) async throws {
			let result = try await ZagNativeAccountInstall.install(source: source, name: entry.name, accountID: accountID, expectedScope: scope,
				onCertificateReady: { @MainActor in _certificateIssue = nil }, renewing: entry, progress: _reportNativeProgress)
			guard case .verified = result else { throw ZagNativeAppInventory.Failure.unverified }
		}
		if !ZagNativeAppInventory.hasSource(entry),
		   let imported = _matchingImports.first(where: { $0.uuid == _sourceImportID }),
		   let source = Storage.shared.getAppDirectory(for: imported) {
			try await renew(source)
		} else {
			try await ZagNativeAppInventory.withSource(entry, body: renew)
		}
	}

	private var _reportNativeProgress: @Sendable (ZagNativeSigningProgress) async -> Void {
		{ @MainActor stage in
			withAnimation(.smooth) { _nativeProgress = max(_nativeProgress ?? .preparing, stage) }
		}
	}
	#endif

	private func _closeSigning() {
		dismiss()
	}

	private func _start() {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		if _signingMethod == .freeAppleAccount {
			_startAccountInstall()
			return
		}
		#endif
		_startSigning(using: _selectedCert())
	}

	private func _startSigning(using certificate: CertificatePair?) {
		guard
			certificate != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		ZagLogger.shared.info("Manual Signing", "Signing started: \(app.name ?? "Unknown") | id=\(app.identifier ?? "unknown") | version=\(app.version ?? "unknown")")
		_isSigning = true

		var options = _temporaryOptions
		if
			options.ppqProtection,
			let identifier = app.identifier,
			let certificate,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
		}

		FR.signPackageFile(
			app,
			using: options,
			icon: appIcon,
			certificate: certificate
		) { error in
			if let error {
				ZagLogger.shared.error("Manual Signing", "\(app.name ?? "Unknown") | id=\(app.identifier ?? "unknown") | \(error.localizedDescription)")
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					_closeSigning()
				}

				UIAlertController.showAlert(
					title: "Error",
					message: error.localizedDescription,
					actions: [ok]
				)
			} else {
				ZagLogger.shared.info("Manual Signing", "Signing completed: \(app.name ?? "Unknown") | id=\(options.appIdentifier ?? app.identifier ?? "unknown") | installAfterSigning=\(options.post_installAppAfterSigned) | deleteImported=\(options.post_deleteAppAfterSigned)")
				if
					options.post_deleteAppAfterSigned,
					!app.isSigned
				{
					Storage.shared.deleteApp(for: app)
				}

				if options.post_installAppAfterSigned {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
						NotificationCenter.default.post(
							name: Notification.Name("Feather.installApp"),
							object: nil
						)
					}
				}
				_closeSigning()
			}
		}
	}}
