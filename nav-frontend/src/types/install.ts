export type InstallState =
  | 'DATABASE_REQUIRED'
  | 'REQUIRED'
  | 'COMPLETED'
  | 'DISABLED'
  | 'NOT_READY'
  | 'UNKNOWN'

export type InstallDatabaseMode = 'EMBEDDED' | 'EXTERNAL'

export type InstallDatabaseSslMode =
  | 'REQUIRE'
  | 'VERIFY_CA'
  | 'VERIFY_FULL'

export type InstallDatabaseSchemaState = 'EMPTY' | 'READY_UNINSTALLED' | 'READY_INSTALLED'

export interface InstallDatabaseConfig {
  mode: InstallDatabaseMode
  host?: string
  port?: number
  database?: string
  username?: string
  password?: string
  sslMode?: InstallDatabaseSslMode
  caCertificatePem?: string
  acknowledgeUnverifiedTls?: boolean
}

export interface InstallDatabaseTestResult {
  ok: true
  connectionTicket: string
  expiresAt: string
  schemaState: InstallDatabaseSchemaState
  requiresInitialization: boolean
}

export interface ConfigureInstallDatabasePayload {
  connectionTicket: string
  initializeSchema: boolean
}

export interface ConfigureInstallDatabaseResult {
  configured: true
  initialized: boolean
  installed: boolean
  restartRequired: boolean
}

export interface InstallEnvironmentCheck {
  ok: boolean
  message: string
}

export interface InstallEnvironmentChecks {
  database: InstallEnvironmentCheck
  schema: InstallEnvironmentCheck
  siteConfig: InstallEnvironmentCheck
  upload: InstallEnvironmentCheck
  redis: InstallEnvironmentCheck
}

export interface InstallStatus {
  state: InstallState
  installationRequired: boolean
  webInstallEnabled: boolean
  ready: boolean
}

export interface InstallCheckResult {
  ready: boolean
  checks: InstallEnvironmentChecks
}

export interface CompleteInstallationPayload {
  siteName: string
  siteDescription: string
  username: string
  nickname: string
  password: string
  confirmPassword: string
}

export interface CompleteInstallationResult {
  installed: true
}
