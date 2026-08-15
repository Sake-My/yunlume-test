<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import {
  CircleCheckFilled,
  CircleCloseFilled,
  Coin,
  Key,
  Lock,
  Refresh,
  Right,
  Setting,
  User,
} from '@element-plus/icons-vue'
import { ElMessage, type FormInstance, type FormRules } from 'element-plus'
import {
  checkInstallationApi,
  completeInstallationApi,
  configureInstallDatabaseApi,
  testInstallDatabaseApi,
} from '@/api/install.api'
import { useAuthStore } from '@/stores/auth.store'
import { useInstallStore } from '@/stores/install.store'
import type {
  CompleteInstallationPayload,
  InstallCheckResult,
  InstallDatabaseMode,
  InstallDatabaseSslMode,
  InstallDatabaseTestResult,
  InstallEnvironmentCheck,
} from '@/types/install'
import { getHttpStatus } from '@/utils/httpError'
import {
  buildInstallDatabaseConfig,
  installDatabaseSchemaLabel,
  isInstallDatabaseTicketExpired,
  type InstallDatabaseFormValue,
} from '@/utils/installDatabase'
import {
  evaluatePasswordPolicy,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
} from '@/utils/passwordPolicy'

interface InstallForm extends CompleteInstallationPayload {
  installToken: string
  database: InstallDatabaseFormValue
  initializeSchema: boolean
  confirmationAccepted: boolean
}

interface CheckItem {
  key: string
  label: string
  check: InstallEnvironmentCheck
}

type InstallDatabaseTestSummary = Omit<InstallDatabaseTestResult, 'connectionTicket'>

const USERNAME_PATTERN = /^[A-Za-z][A-Za-z0-9._-]{2,31}$/
const INSTALL_TOKEN_PATTERN = /^[0-9a-f]{64}$/
const DATABASE_DNS_HOST_PATTERN = /^[A-Za-z0-9.-]{1,253}$/
const DATABASE_IPV6_HOST_PATTERN = /^[0-9A-Fa-f:.%]+$/
const DATABASE_NAME_PATTERN = /^[A-Za-z0-9_.-]{1,63}$/
const SSL_MODE_OPTIONS: Array<{ value: InstallDatabaseSslMode; label: string; help: string }> = [
  { value: 'VERIFY_FULL', label: '完整验证', help: '验证证书链及服务器主机名' },
  { value: 'VERIFY_CA', label: '验证 CA', help: '验证证书链，不校验主机名' },
  { value: 'REQUIRE', label: '仅要求加密', help: '建立加密连接，但不验证证书或主机名' },
]
const DATABASE_CA_MAX_BYTES = 65_536
const formRef = ref<FormInstance>()
const caFileInput = ref<HTMLInputElement>()
const activeStep = ref(0)
const testingDatabase = ref(false)
const configuringDatabase = ref(false)
const checking = ref(false)
const submitting = ref(false)
const submissionFinished = ref(false)
const environmentCheck = ref<InstallCheckResult | null>(null)
const databaseTest = ref<InstallDatabaseTestSummary | null>(null)
const databaseTicket = ref('')
const databaseConfigured = ref(false)
const databaseStepWasUsed = ref(false)
const configuredDatabaseModeKnown = ref(false)
const form = reactive<InstallForm>({
  installToken: '',
  database: {
    mode: 'EMBEDDED',
    host: '',
    port: 5432,
    database: '',
    username: '',
    password: '',
    sslMode: 'VERIFY_FULL',
    caCertificatePem: '',
    acknowledgeUnverifiedTls: false,
  },
  initializeSchema: false,
  siteName: 'iLinks',
  siteDescription: '简洁、快速、可自定义的网址导航',
  username: 'admin',
  nickname: '管理员',
  password: '',
  confirmPassword: '',
  confirmationAccepted: false,
})

const installStore = useInstallStore()
const authStore = useAuthStore()
const router = useRouter()
const insecureTransport = typeof window !== 'undefined' && window.location.protocol !== 'https:'
const status = computed(() => installStore.status)
const databaseMode = computed<InstallDatabaseMode>(() => form.database.mode)
const databaseTestReady = computed(() => Boolean(
  databaseTest.value
  && databaseTicket.value
  && !isInstallDatabaseTicketExpired(databaseTest.value),
))
const databaseFieldsLocked = computed(() => Boolean(
  testingDatabase.value
  || configuringDatabase.value
  || databaseTestReady.value
  || databaseConfigured.value,
))
const databaseCanConfigure = computed(() => Boolean(
  databaseTestReady.value
  && databaseTest.value?.schemaState !== 'READY_INSTALLED'
  && (
    !databaseTest.value?.requiresInitialization
    || form.initializeSchema
  ),
))
const databaseSchemaLabel = computed(() => (
  databaseTest.value ? installDatabaseSchemaLabel(databaseTest.value.schemaState) : ''
))
const databaseConfigurationLabel = computed(() => (
  !configuredDatabaseModeKnown.value
    ? '已配置 PostgreSQL（已通过检查）'
    : databaseMode.value === 'EMBEDDED'
      ? '内置 PostgreSQL（已通过测试）'
      : '外部 PostgreSQL（已通过测试）'
))
const databaseSslModeHelp = computed(() => (
  SSL_MODE_OPTIONS.find((item) => item.value === form.database.sslMode)?.help ?? ''
))
const canEnterDatabaseStep = computed(() => {
  const currentStatus = status.value
  return Boolean(
    currentStatus
    && ['DATABASE_REQUIRED', 'REQUIRED'].includes(currentStatus.state)
    && currentStatus.webInstallEnabled
    && !installStore.error,
  )
})
const environmentReady = computed(() => {
  const currentStatus = status.value
  return Boolean(
    environmentCheck.value?.ready
    && databaseConfigured.value
    && currentStatus?.state === 'REQUIRED'
    && currentStatus.webInstallEnabled
    && currentStatus.ready
    && !installStore.error,
  )
})
const canCheckEnvironment = computed(() => {
  const currentStatus = status.value
  return Boolean(
    databaseConfigured.value
    && currentStatus?.state === 'REQUIRED'
    && currentStatus.webInstallEnabled
    && currentStatus.ready
    && !installStore.error,
  )
})
const checkItems = computed<CheckItem[]>(() => {
  const checks = environmentCheck.value?.checks
  if (!checks) return []
  return [
    { key: 'database', label: 'PostgreSQL 数据库', check: checks.database },
    { key: 'schema', label: '数据库结构', check: checks.schema },
    { key: 'siteConfig', label: '站点初始化条件', check: checks.siteConfig },
    { key: 'upload', label: '上传存储目录', check: checks.upload },
    { key: 'redis', label: 'Redis 连接', check: checks.redis },
  ]
})
const passwordPolicy = computed(() => evaluatePasswordPolicy(form.password, form.username))
const strengthLabel = computed(() => ({
  empty: '等待输入',
  weak: '未满足要求',
  medium: '符合要求',
  strong: '强密码',
}[passwordPolicy.value.strength]))
const strengthWidth = computed(() => ({
  empty: '0%',
  weak: '28%',
  medium: '68%',
  strong: '100%',
}[passwordPolicy.value.strength]))
function isTrimmedSingleLine(value: string): boolean {
  return value === value.trim() && ![...value].some((character) => {
    const codePoint = character.codePointAt(0) ?? 0
    return codePoint <= 0x1f
      || (codePoint >= 0x7f && codePoint <= 0x9f)
      || codePoint === 0x2028
      || codePoint === 0x2029
  })
}

function isValidDatabaseHost(value: string): boolean {
  const dns = DATABASE_DNS_HOST_PATTERN.test(value)
    && !value.startsWith('.')
    && !value.endsWith('.')
    && !value.startsWith('-')
    && !value.endsWith('-')
    && !value.includes('..')
  const ipv6 = value.includes(':') && DATABASE_IPV6_HOST_PATTERN.test(value)
  return dns || ipv6
}

function installRequestErrorMessage(error: unknown, statusCode: number | undefined, fallback: string): string {
  if (statusCode === 403) {
    return '请求被服务器拒绝。请确认 NAV_WEB_INSTALL_ENABLED 已启用，并优先通过 HTTPS 打开安装页；仅在完全受信任的局域网内，才可显式设置 NAV_ALLOW_INSECURE_DATABASE_SETUP=true 并重启服务。'
  }
  return error instanceof Error && error.message ? error.message : fallback
}

function skipExternalDatabaseValidation(): boolean {
  return form.database.mode !== 'EXTERNAL'
}

function databaseUsesCaCertificate(): boolean {
  return form.database.mode === 'EXTERNAL' && form.database.sslMode !== 'REQUIRE'
}

function isValidCaCertificatePem(value: string): boolean {
  return value.includes('-----BEGIN CERTIFICATE-----')
    && value.includes('-----END CERTIFICATE-----')
    && new TextEncoder().encode(value).byteLength <= DATABASE_CA_MAX_BYTES
}

const rules: FormRules = {
  siteName: [
    { required: true, message: '请输入站点名称', trigger: 'blur' },
    { max: 50, message: '站点名称不能超过 50 个字符', trigger: ['blur', 'change'] },
    {
      validator: (_rule, value, callback) => {
        if (!isTrimmedSingleLine(value ?? '')) return callback(new Error('站点名称必须是首尾无空格的单行文字'))
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  siteDescription: [
    { max: 255, message: '站点简介不能超过 255 个字符', trigger: ['blur', 'change'] },
    {
      validator: (_rule, value, callback) => {
        if (!isTrimmedSingleLine(value ?? '')) return callback(new Error('站点简介必须是首尾无空格的单行文字'))
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  username: [
    { required: true, message: '请输入管理员用户名', trigger: 'blur' },
    {
      pattern: USERNAME_PATTERN,
      message: '用户名需以英文字母开头，由 3–32 位字母、数字、点、下划线或短横线组成',
      trigger: ['blur', 'change'],
    },
  ],
  nickname: [
    { required: true, message: '请输入管理员昵称', trigger: 'blur' },
    { max: 50, message: '管理员昵称不能超过 50 个字符', trigger: ['blur', 'change'] },
    {
      validator: (_rule, value, callback) => {
        if (!isTrimmedSingleLine(value ?? '')) return callback(new Error('管理员昵称必须是首尾无空格的单行文字'))
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  password: [
    { required: true, message: '请输入管理员密码', trigger: 'blur' },
    {
      validator: (_rule, value, callback) => {
        const result = evaluatePasswordPolicy(value ?? '', form.username)
        if (!result.lengthValid) {
          return callback(new Error(`密码至少 ${PASSWORD_MIN_LENGTH} 个字符，且不能超过 ${PASSWORD_MAX_LENGTH} 个 UTF-8 字节`))
        }
        if (!result.whitespaceFree) return callback(new Error('密码不能包含空格或其他空白字符'))
        if (!result.categoriesValid) return callback(new Error('请至少使用大写字母、小写字母、数字、符号中的三类'))
        if (!result.usernameFree) return callback(new Error('密码不能包含管理员用户名'))
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  confirmPassword: [
    { required: true, message: '请再次输入管理员密码', trigger: 'blur' },
    {
      validator: (_rule, value, callback) => {
        if (value !== form.password) return callback(new Error('两次输入的密码不一致'))
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  installToken: [
    { required: true, message: '请输入服务器安装口令', trigger: 'blur' },
    {
      pattern: INSTALL_TOKEN_PATTERN,
      message: '安装口令应为 .env 中配置的 64 位小写十六进制值',
      trigger: ['blur', 'change'],
    },
  ],
  'database.host': [
    {
      validator: (_rule, value, callback) => {
        if (skipExternalDatabaseValidation()) return callback()
        if (typeof value !== 'string' || !value) return callback(new Error('请输入 PostgreSQL 主机名或 IP 地址'))
        if (value !== value.trim() || !isValidDatabaseHost(value)) {
          return callback(new Error('请输入不含协议、路径、账号或空格的 DNS 主机名、IPv4 或 IPv6 地址'))
        }
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  'database.port': [
    {
      validator: (_rule, value, callback) => {
        if (skipExternalDatabaseValidation()) return callback()
        const port = Number(value)
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          return callback(new Error('端口必须是 1–65535 之间的整数'))
        }
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  'database.database': [
    {
      validator: (_rule, value, callback) => {
        if (skipExternalDatabaseValidation()) return callback()
        if (typeof value !== 'string' || !value) return callback(new Error('请输入数据库名称'))
        if (value !== value.trim() || !DATABASE_NAME_PATTERN.test(value)) {
          return callback(new Error('数据库名称只能包含英文字母、数字、点、下划线和短横线，且不超过 63 个字符'))
        }
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  'database.username': [
    {
      validator: (_rule, value, callback) => {
        if (skipExternalDatabaseValidation()) return callback()
        if (typeof value !== 'string' || !value) return callback(new Error('请输入数据库用户名'))
        if (!isTrimmedSingleLine(value) || value.length > 128) {
          return callback(new Error('数据库用户名应为首尾无空格的单行文字，且不超过 128 个字符'))
        }
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  'database.password': [
    {
      validator: (_rule, value, callback) => {
        if (skipExternalDatabaseValidation() || databaseTestReady.value) return callback()
        if (typeof value !== 'string' || !value) return callback(new Error('请输入数据库密码'))
        if (value.length > 1024) return callback(new Error('数据库密码长度不能超过 1024 个字符'))
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  'database.sslMode': [
    {
      validator: (_rule, value, callback) => {
        if (skipExternalDatabaseValidation()) return callback()
        if (!SSL_MODE_OPTIONS.some((item) => item.value === value)) {
          return callback(new Error('请选择有效的 SSL 模式'))
        }
        callback()
      },
      trigger: 'change',
    },
  ],
  'database.caCertificatePem': [
    {
      validator: (_rule, value, callback) => {
        if (!databaseUsesCaCertificate()) return callback()
        if (typeof value !== 'string' || !value.trim()) {
          return callback(new Error('VERIFY_CA / VERIFY_FULL 必须提供 CA 证书 PEM'))
        }
        if (!isValidCaCertificatePem(value)) {
          return callback(new Error('请输入不超过 64KiB 的完整 PEM CA 证书'))
        }
        callback()
      },
      trigger: ['blur', 'change'],
    },
  ],
  'database.acknowledgeUnverifiedTls': [
    {
      validator: (_rule, value, callback) => {
        if (
          form.database.mode === 'EXTERNAL'
          && form.database.sslMode === 'REQUIRE'
          && value !== true
        ) {
          return callback(new Error('使用 REQUIRE 前必须确认未验证证书和主机名的风险'))
        }
        callback()
      },
      trigger: 'change',
    },
  ],
  initializeSchema: [
    {
      validator: (_rule, value, callback) => {
        if (databaseTest.value?.requiresInitialization && value !== true) {
          return callback(new Error('空数据库需要确认初始化系统表结构'))
        }
        callback()
      },
      trigger: 'change',
    },
  ],
  confirmationAccepted: [
    {
      validator: (_rule, value, callback) => {
        if (value !== true) return callback(new Error('请确认以上信息并知晓安装完成后向导会关闭'))
        callback()
      },
      trigger: 'change',
    },
  ],
}

let restartPollGeneration = 0
let databaseTicketExpiryTimer: number | undefined

async function validateFields(fields: string[]): Promise<boolean> {
  if (!formRef.value) return false
  return formRef.value.validateField(fields).then(() => true).catch(() => false)
}

function scrubDatabaseAuthorization(clearTest = true) {
  if (databaseTicketExpiryTimer !== undefined) {
    window.clearTimeout(databaseTicketExpiryTimer)
    databaseTicketExpiryTimer = undefined
  }
  form.database.password = ''
  form.database.caCertificatePem = ''
  form.database.acknowledgeUnverifiedTls = false
  databaseTicket.value = ''
  if (clearTest) {
    databaseTest.value = null
    form.initializeSchema = false
  }
}

function scheduleDatabaseTicketExpiry(expiresAt: string) {
  if (databaseTicketExpiryTimer !== undefined) window.clearTimeout(databaseTicketExpiryTimer)
  const delay = Math.max(0, Date.parse(expiresAt) - Date.now())
  databaseTicketExpiryTimer = window.setTimeout(() => {
    databaseTicket.value = ''
    form.initializeSchema = false
    databaseTicketExpiryTimer = undefined
  }, delay)
}

function invalidateDatabaseTest() {
  if (databaseConfigured.value) return
  if (databaseTicketExpiryTimer !== undefined) {
    window.clearTimeout(databaseTicketExpiryTimer)
    databaseTicketExpiryTimer = undefined
  }
  databaseTicket.value = ''
  databaseTest.value = null
  form.initializeSchema = false
  environmentCheck.value = null
}

function handleDatabaseModeChange() {
  scrubDatabaseAuthorization(true)
  environmentCheck.value = null
  void formRef.value?.clearValidate([
    'database.host',
    'database.port',
    'database.database',
    'database.username',
    'database.password',
    'database.sslMode',
    'database.caCertificatePem',
    'database.acknowledgeUnverifiedTls',
  ])
}

function handleDatabaseSslModeChange() {
  invalidateDatabaseTest()
  if (form.database.sslMode === 'REQUIRE') form.database.caCertificatePem = ''
  else form.database.acknowledgeUnverifiedTls = false
  void formRef.value?.clearValidate([
    'database.caCertificatePem',
    'database.acknowledgeUnverifiedTls',
  ])
}

function selectCaCertificateFile() {
  caFileInput.value?.click()
}

async function handleCaCertificateFile(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  if (file.size > DATABASE_CA_MAX_BYTES) {
    scrubDatabaseAuthorization(true)
    ElMessage.error('CA 证书文件不能超过 64KiB')
    return
  }
  try {
    const pem = await file.text()
    if (!isValidCaCertificatePem(pem)) {
      scrubDatabaseAuthorization(true)
      ElMessage.error('文件不是完整的 PEM CA 证书')
      return
    }
    form.database.caCertificatePem = pem
    invalidateDatabaseTest()
    await formRef.value?.validateField('database.caCertificatePem').catch(() => undefined)
    ElMessage.success('CA 证书已载入当前页面内存')
  } catch {
    scrubDatabaseAuthorization(true)
    ElMessage.error('无法读取 CA 证书文件')
  }
}

function databaseValidationFields(): string[] {
  if (databaseMode.value === 'EMBEDDED') return ['installToken']
  const fields = [
    'installToken',
    'database.host',
    'database.port',
    'database.database',
    'database.username',
    'database.password',
    'database.sslMode',
  ]
  fields.push(form.database.sslMode === 'REQUIRE'
    ? 'database.acknowledgeUnverifiedTls'
    : 'database.caCertificatePem')
  return fields
}

async function testDatabaseConnection() {
  if (testingDatabase.value || configuringDatabase.value || databaseConfigured.value) return
  if (!await validateFields(databaseValidationFields())) return
  if (!canEnterDatabaseStep.value) {
    ElMessage.error('服务器尚未开放数据库配置，请先修复部署配置')
    return
  }

  const database = buildInstallDatabaseConfig(form.database)
  testingDatabase.value = true
  databaseTicket.value = ''
  databaseTest.value = null
  form.initializeSchema = false
  try {
    const result = await testInstallDatabaseApi(
      form.installToken,
      database,
    )
    databaseTicket.value = result.connectionTicket
    databaseTest.value = {
      ok: true,
      expiresAt: result.expiresAt,
      schemaState: result.schemaState,
      requiresInitialization: result.requiresInitialization,
    }
    scheduleDatabaseTicketExpiry(result.expiresAt)
    form.database.password = ''
    form.database.caCertificatePem = ''
    ElMessage.success('数据库连接与结构检查通过，密码和 CA 证书已从页面内存清除')
  } catch (error) {
    const statusCode = getHttpStatus(error)
    scrubDatabaseAuthorization(true)
    if (statusCode === 401) {
      form.installToken = ''
      activeStep.value = 0
    }
    if (statusCode === 409) await refreshStatus(true)
    const fallback = statusCode === 401
      ? '安装口令不正确，请重新输入'
      : '数据库连接或结构检查失败，请核对配置后重试'
    ElMessage.error(installRequestErrorMessage(error, statusCode, fallback))
  } finally {
    testingDatabase.value = false
  }
}

async function waitForDatabaseRestart() {
  const generation = ++restartPollGeneration
  const deadline = Date.now() + 90_000
  while (Date.now() < deadline && generation === restartPollGeneration) {
    await new Promise<void>((resolve) => window.setTimeout(resolve, 2_000))
    if (generation !== restartPollGeneration) return null
    const latest = await installStore.fetchStatus(true)
    if (latest?.state === 'COMPLETED') return latest
    if (latest?.state === 'REQUIRED' && latest.ready && !installStore.error) return latest
  }
  return null
}

async function configureDatabase() {
  if (testingDatabase.value || configuringDatabase.value || databaseConfigured.value) return
  if (!databaseTestReady.value || !databaseTest.value || !databaseTicket.value) {
    scrubDatabaseAuthorization(true)
    ElMessage.warning('连接测试结果已失效，请重新输入数据库密码并测试')
    return
  }
  if (databaseTest.value.schemaState === 'READY_INSTALLED') {
    scrubDatabaseAuthorization(true)
    ElMessage.error('该数据库已存在完成安装的站点，不能用于首次初始化')
    return
  }
  if (!await validateFields(['initializeSchema'])) return

  configuringDatabase.value = true
  try {
    const result = await configureInstallDatabaseApi(form.installToken, {
      connectionTicket: databaseTicket.value,
      initializeSchema: databaseTest.value.requiresInitialization
        ? form.initializeSchema
        : false,
    })
    scrubDatabaseAuthorization(false)
    databaseConfigured.value = true
    databaseStepWasUsed.value = true
    configuredDatabaseModeKnown.value = true

    if (result.installed) {
      await refreshStatus(true)
      return
    }

    let latest = null
    if (result.restartRequired) {
      ElMessage.info('数据库配置已保存，正在等待服务重启，请勿关闭页面')
      latest = await waitForDatabaseRestart()
    } else {
      latest = await installStore.fetchStatus(true)
    }
    if (latest?.state === 'COMPLETED') {
      scrubSensitiveFields()
      await router.replace({ name: 'admin-login' })
      return
    }
    if (latest?.state !== 'REQUIRED' || !latest.ready || installStore.error) {
      databaseConfigured.value = false
      throw new Error('数据库已保存，但服务未在 90 秒内恢复，请检查服务日志后重试')
    }
    await checkEnvironment()
  } catch (error) {
    const statusCode = getHttpStatus(error)
    scrubDatabaseAuthorization(true)
    databaseConfigured.value = false
    if (statusCode === 401) {
      form.installToken = ''
      activeStep.value = 0
    }
    if (statusCode === 409) await refreshStatus(true)
    const fallback = statusCode === 401
      ? '安装口令不正确，请重新输入'
      : '数据库配置应用失败，请重新测试连接'
    ElMessage.error(installRequestErrorMessage(error, statusCode, fallback))
  } finally {
    configuringDatabase.value = false
  }
}

async function nextStep() {
  if (testingDatabase.value || configuringDatabase.value || checking.value || submitting.value) return
  if (activeStep.value === 0) {
    if (!await validateFields(['installToken'])) return
    if (!canEnterDatabaseStep.value) {
      ElMessage.error('服务器尚未开放首次数据库配置，请先修复部署配置')
      return
    }
    if (status.value?.state === 'REQUIRED') {
      databaseConfigured.value = true
      databaseStepWasUsed.value = false
      configuredDatabaseModeKnown.value = false
      await checkEnvironment()
      return
    }
    databaseStepWasUsed.value = true
    activeStep.value = 1
    return
  }
  if (activeStep.value === 1) {
    if (databaseConfigured.value) {
      activeStep.value = 2
      return
    }
    await configureDatabase()
    return
  }
  if (activeStep.value === 2) {
    if (!environmentReady.value) {
      ElMessage.warning('请先完成全部环境检查')
      return
    }
    activeStep.value = 3
    return
  }
  if (activeStep.value === 3) {
    if (!await validateFields(['siteName', 'siteDescription'])) return
    activeStep.value = 4
    return
  }
  if (activeStep.value === 4) {
    if (!await validateFields(['username', 'nickname', 'password', 'confirmPassword'])) return
    activeStep.value = 5
  }
}

function previousStep() {
  if (
    !testingDatabase.value
    && !configuringDatabase.value
    && !checking.value
    && !submitting.value
    && activeStep.value > 0
  ) {
    if (activeStep.value === 2 && !databaseStepWasUsed.value) activeStep.value = 0
    else activeStep.value -= 1
  }
}

function scrubSensitiveFields() {
  form.installToken = ''
  scrubDatabaseAuthorization(true)
  form.password = ''
  form.confirmPassword = ''
}

async function refreshStatus(force = true) {
  const latest = await installStore.fetchStatus(force)
  if (latest?.state === 'COMPLETED') {
    scrubSensitiveFields()
    await router.replace({ name: 'admin-login' })
  }
}

async function checkEnvironment() {
  if (checking.value || submitting.value) return
  if (!await validateFields(['installToken'])) return
  if (!canCheckEnvironment.value) {
    ElMessage.error('服务器尚未开放安装检查，请先修复部署配置')
    return
  }

  checking.value = true
  try {
    environmentCheck.value = await checkInstallationApi(form.installToken)
    activeStep.value = 2
    if (environmentCheck.value.ready) ElMessage.success('完整运行环境检查通过')
    else ElMessage.warning('运行环境尚未就绪，请按检查结果修复后重试')
  } catch (error) {
    const statusCode = getHttpStatus(error)
    environmentCheck.value = null
    scrubSensitiveFields()
    activeStep.value = 0
    if (statusCode === 409) await refreshStatus(true)
    const fallback = statusCode === 401
      ? '安装口令不正确，请重新输入'
      : '无法完成安装检查，请稍后重试'
    ElMessage.error(installRequestErrorMessage(error, statusCode, fallback))
  } finally {
    checking.value = false
  }
}

async function completeInstallation() {
  if (submitting.value || submissionFinished.value) return
  if (!await validateFields(['confirmationAccepted'])) return

  const latest = await installStore.fetchStatus(true)
  if (latest?.state === 'COMPLETED') {
    scrubSensitiveFields()
    authStore.clearSession()
    await router.replace({ name: 'admin-login' })
    return
  }
  if (
    !latest
    || installStore.error
    || !latest.webInstallEnabled
    || !latest.ready
  ) {
    scrubSensitiveFields()
    environmentCheck.value = null
    form.confirmationAccepted = false
    activeStep.value = 0
    ElMessage.error('安装状态已变化或暂时无法确认，请重新检查环境')
    return
  }

  submitting.value = true
  try {
    const installToken = form.installToken
    const latestCheck = await checkInstallationApi(installToken)
    environmentCheck.value = latestCheck
    if (!latestCheck.ready) {
      scrubSensitiveFields()
      environmentCheck.value = null
      form.confirmationAccepted = false
      activeStep.value = 0
      ElMessage.error('运行环境检查已发生变化，请修复后重新确认')
      return
    }
    const payload: CompleteInstallationPayload = {
      siteName: form.siteName.trim(),
      siteDescription: form.siteDescription.trim(),
      username: form.username.trim(),
      nickname: form.nickname.trim(),
      password: form.password,
      confirmPassword: form.confirmPassword,
    }
    await completeInstallationApi(installToken, payload)
    submissionFinished.value = true
    scrubSensitiveFields()
    environmentCheck.value = null
    form.confirmationAccepted = false
    installStore.markInstalled()
    authStore.clearSession()
    await router.replace({ name: 'admin-login', query: { installed: '1' } })
    ElMessage.success('安装完成，请使用新管理员账号登录')
  } catch (error) {
    const statusCode = getHttpStatus(error)
    scrubSensitiveFields()
    form.confirmationAccepted = false
    if (statusCode === 409) {
      await refreshStatus(true)
    } else {
      activeStep.value = 0
    }
    const fallback = statusCode === 401
      ? '安装口令不正确，请检查后重试'
      : '安装失败，请检查配置后重试'
    ElMessage.error(installRequestErrorMessage(error, statusCode, fallback))
  } finally {
    submitting.value = false
  }
}

function handleEnter(event: KeyboardEvent) {
  const target = event.target
  if (
    target instanceof HTMLTextAreaElement
    || target instanceof HTMLButtonElement
    || (target instanceof HTMLInputElement && ['checkbox', 'radio', 'file'].includes(target.type))
  ) return
  if (activeStep.value === 5) void completeInstallation()
  else void nextStep()
}

onMounted(() => {
  void refreshStatus(false)
})
onBeforeUnmount(() => {
  restartPollGeneration += 1
  scrubSensitiveFields()
  environmentCheck.value = null
})
</script>

<template>
  <div class="install-page">
    <aside class="install-page__story" aria-label="iLinks 首次部署说明">
      <RouterLink class="install-page__brand" to="/">
        <span>i</span>
        <strong>iLinks</strong>
      </RouterLink>
      <div class="install-page__story-copy">
        <p>FIRST-RUN SETUP</p>
        <h1>几步完成部署，<br />建立你的导航起点。</h1>
        <span>连接内置或外部 PostgreSQL，检查运行环境并创建首位管理员。安装完成后，此入口会自动关闭。</span>
      </div>
      <small>ILINKS NAVIGATION SYSTEM · SECURE INSTALLATION</small>
    </aside>

    <main class="install-page__main">
      <section class="install-wizard" aria-labelledby="install-title">
        <header class="install-wizard__heading">
          <div class="install-wizard__mobile-brand">iLinks</div>
          <p>DEPLOYMENT WIZARD</p>
          <h2 id="install-title">首次部署向导</h2>
          <span>安装只允许执行一次，请按步骤完成必要配置。</span>
        </header>

        <el-steps class="install-wizard__steps" :active="activeStep" finish-status="success" align-center>
          <el-step title="口令" />
          <el-step title="数据库" />
          <el-step title="环境" />
          <el-step title="站点" />
          <el-step title="账号" />
          <el-step title="确认" />
        </el-steps>

        <el-form
          ref="formRef"
          :model="form"
          :rules="rules"
          label-position="top"
          class="install-wizard__form"
          @keyup.enter="handleEnter"
        >
          <section v-show="activeStep === 0" class="install-step" aria-labelledby="install-token-title">
            <div class="install-step__heading">
              <span><Key /></span>
              <div>
                <h3 id="install-token-title">验证安装口令</h3>
                <p>只有持有服务器安装口令的部署者才能读取详细检查并完成安装。</p>
              </div>
            </div>

            <div class="install-status" aria-live="polite">
              <el-alert
                v-if="installStore.error"
                type="error"
                :closable="false"
                title="无法确认安装状态"
                :description="installStore.error"
                show-icon
              />
              <el-alert
                v-else-if="status?.state === 'UNKNOWN'"
                type="error"
                :closable="false"
                title="暂时无法确认系统安装状态"
                description="为避免误导已有站点，页面不会自动进入安装。请检查服务端和数据库后重新读取状态。"
                show-icon
              />
              <el-alert
                v-else-if="status?.state === 'DISABLED'"
                type="warning"
                :closable="false"
                title="网页安装未启用"
                description="请在服务器 .env 中启用网页安装并配置安装口令，然后重新检查。"
                show-icon
              />
              <el-alert
                v-else-if="status?.state === 'NOT_READY'"
                type="warning"
                :closable="false"
                title="服务器安装口令配置不符合要求"
                description="请在 .env 中配置 64 位小写十六进制安装口令，然后重新读取状态。数据库与站点条件会在口令验证后单独检查。"
                show-icon
              />
              <el-alert
                v-else-if="status?.state === 'DATABASE_REQUIRED'"
                type="info"
                :closable="false"
                title="这是尚未配置数据库的新实例"
                description="验证安装口令后，可选择内置 PostgreSQL 或连接外部 PostgreSQL。"
                show-icon
              />
              <el-alert
                v-else-if="status?.state === 'REQUIRED'"
                type="info"
                :closable="false"
                title="已确认这是尚未安装的新实例"
                description="数据库连接已由服务器管理。验证安装口令后将直接执行完整环境检查。"
                show-icon
              />
            </div>

            <el-form-item label="服务器安装口令" prop="installToken">
              <el-input
                v-model="form.installToken"
                type="password"
                show-password
                maxlength="64"
                autocomplete="off"
                autocapitalize="none"
                spellcheck="false"
                placeholder="输入 .env 中配置的安装口令"
                @input="invalidateDatabaseTest"
              >
                <template #prefix><Key /></template>
              </el-input>
              <p class="install-token-help">口令只保留在当前页面内存并通过请求头发送，不写入浏览器存储或 URL。公网部署请先启用 HTTPS。</p>
            </el-form-item>
            <el-button class="install-step__retry" :loading="installStore.loading" @click="refreshStatus(true)">
              <Refresh />重新读取安装状态
            </el-button>
          </section>

          <section v-show="activeStep === 1" class="install-step" aria-labelledby="install-database-title">
            <div class="install-step__heading">
              <span><Coin /></span>
              <div>
                <h3 id="install-database-title">配置 PostgreSQL</h3>
                <p>可直接使用 Compose 内置数据库，也可连接由你维护的外部 PostgreSQL。</p>
              </div>
            </div>

            <fieldset class="install-database-mode">
              <legend>数据库来源</legend>
              <el-radio-group
                v-model="form.database.mode"
                :disabled="databaseFieldsLocked"
                aria-label="选择 PostgreSQL 来源"
                @change="handleDatabaseModeChange"
              >
                <el-radio-button value="EMBEDDED">内置 PostgreSQL</el-radio-button>
                <el-radio-button value="EXTERNAL">外部 PostgreSQL</el-radio-button>
              </el-radio-group>
              <p v-if="databaseMode === 'EMBEDDED'">
                使用服务器部署配置中的 Compose PostgreSQL；连接账号与密码继续由服务器环境变量管理。
              </p>
              <p v-else>
                请提前创建空白、专用的 PostgreSQL 数据库，并使用非 superuser、但具备建表、索引、序列和迁移所需 DDL 权限的账号。
              </p>
            </fieldset>

            <div
              v-if="databaseMode === 'EXTERNAL'"
              class="install-database-fields"
              :aria-busy="testingDatabase || configuringDatabase"
            >
              <div class="install-database-prerequisites">
                <el-alert
                  type="info"
                  :closable="false"
                  title="连接凭据仅用于一次性测试"
                  description="测试通过后只保留短期票据；数据库密码和 CA 证书不会写入 URL、localStorage 或 sessionStorage。"
                  show-icon
                />
                <el-alert
                  v-if="insecureTransport"
                  type="error"
                  :closable="false"
                  title="当前页面未使用 HTTPS"
                  description="数据库密码和 CA 证书会通过未加密 HTTP 传输，可能被同网段人员窃取。公网或非完全受信任网络请停止操作，先配置 HTTPS。"
                  show-icon
                />
              </div>

              <div class="install-form-grid is-database-address">
                <el-form-item label="数据库主机" prop="database.host">
                  <el-input
                    v-model="form.database.host"
                    :disabled="databaseFieldsLocked"
                    maxlength="253"
                    autocomplete="off"
                    autocapitalize="none"
                    spellcheck="false"
                    placeholder="db.example.com"
                    @input="invalidateDatabaseTest"
                  />
                </el-form-item>
                <el-form-item label="端口" prop="database.port">
                  <el-input
                    v-model.number="form.database.port"
                    :disabled="databaseFieldsLocked"
                    type="number"
                    inputmode="numeric"
                    min="1"
                    max="65535"
                    autocomplete="off"
                    @input="invalidateDatabaseTest"
                  />
                </el-form-item>
              </div>

              <div class="install-form-grid is-two-column">
                <el-form-item label="数据库名称" prop="database.database">
                  <el-input
                    v-model="form.database.database"
                    :disabled="databaseFieldsLocked"
                    maxlength="63"
                    autocomplete="off"
                    autocapitalize="none"
                    spellcheck="false"
                    @input="invalidateDatabaseTest"
                  />
                </el-form-item>
                <el-form-item label="数据库用户名" prop="database.username">
                  <el-input
                    v-model="form.database.username"
                    :disabled="databaseFieldsLocked"
                    maxlength="128"
                    autocomplete="username"
                    autocapitalize="none"
                    spellcheck="false"
                    @input="invalidateDatabaseTest"
                  />
                </el-form-item>
              </div>

              <el-form-item label="数据库密码" prop="database.password">
                <el-input
                  v-model="form.database.password"
                  :disabled="databaseFieldsLocked"
                  type="password"
                  show-password
                  maxlength="1024"
                  autocomplete="new-password"
                  autocapitalize="none"
                  spellcheck="false"
                  placeholder="只保留到连接测试完成"
                  @input="invalidateDatabaseTest"
                >
                  <template #prefix><Lock /></template>
                </el-input>
              </el-form-item>

              <el-form-item label="SSL 模式" prop="database.sslMode">
                <el-select
                  v-model="form.database.sslMode"
                  :disabled="databaseFieldsLocked"
                  class="install-database-ssl-select"
                  @change="handleDatabaseSslModeChange"
                >
                  <el-option
                    v-for="option in SSL_MODE_OPTIONS"
                    :key="option.value"
                    :label="option.label"
                    :value="option.value"
                  />
                </el-select>
                <p class="install-token-help">{{ databaseSslModeHelp }}</p>
              </el-form-item>

              <div v-if="databaseUsesCaCertificate()" class="install-ca-certificate">
                <el-form-item label="CA 证书 PEM" prop="database.caCertificatePem">
                  <el-input
                    v-model="form.database.caCertificatePem"
                    :disabled="databaseFieldsLocked"
                    type="textarea"
                    :rows="4"
                    maxlength="65536"
                    resize="vertical"
                    autocomplete="off"
                    spellcheck="false"
                    placeholder="-----BEGIN CERTIFICATE-----"
                    @input="invalidateDatabaseTest"
                  />
                </el-form-item>
                <input
                  ref="caFileInput"
                  class="install-ca-file-input"
                  type="file"
                  accept=".pem,.crt,.cer,text/plain,application/x-pem-file,application/pkix-cert"
                  tabindex="-1"
                  aria-hidden="true"
                  @change="handleCaCertificateFile"
                />
                <el-button
                  :disabled="databaseFieldsLocked"
                  class="install-ca-certificate__upload"
                  @click="selectCaCertificateFile"
                >
                  选择 PEM 文件
                </el-button>
                <p>最多 64KiB，仅载入当前页面内存；测试成功、失败或离开页面后立即清除。</p>
              </div>

              <el-form-item
                v-else
                prop="database.acknowledgeUnverifiedTls"
                class="install-database-risk"
              >
                <el-alert
                  type="warning"
                  :closable="false"
                  title="REQUIRE 仅加密传输，不验证证书或主机名"
                  description="该模式不能确认连接的是目标数据库，只有在你理解并接受中间人攻击风险时使用。"
                  show-icon
                />
                <el-checkbox
                  v-model="form.database.acknowledgeUnverifiedTls"
                  :disabled="databaseFieldsLocked"
                  @change="invalidateDatabaseTest"
                >
                  我已理解 REQUIRE 不校验证书与主机名的风险
                </el-checkbox>
              </el-form-item>
            </div>

            <div class="install-database-result" aria-live="polite">
              <el-alert
                v-if="databaseConfigured"
                type="success"
                :closable="false"
                title="数据库配置已应用"
                :description="databaseConfigurationLabel"
                show-icon
              />
              <el-alert
                v-else-if="databaseTestReady"
                :type="databaseTest?.schemaState === 'READY_INSTALLED' ? 'error' : 'success'"
                :closable="false"
                title="连接测试通过"
                :description="`${databaseSchemaLabel}。连接票据约 5 分钟内有效，密码与 CA 证书已清除。`"
                show-icon
              />
              <el-alert
                v-else-if="databaseTest"
                type="warning"
                :closable="false"
                title="连接票据已过期"
                description="请重新输入数据库密码，并再次测试连接。"
                show-icon
              />
            </div>

            <el-form-item
              v-if="databaseTestReady && databaseTest?.requiresInitialization"
              prop="initializeSchema"
              class="install-database-initialize"
            >
              <el-checkbox v-model="form.initializeSchema">
                我确认在这个空数据库中创建 iLinks 系统表、索引和迁移登记。
              </el-checkbox>
            </el-form-item>

            <div class="install-database-actions">
              <el-button
                v-if="!databaseTestReady && !databaseConfigured"
                type="primary"
                :loading="testingDatabase"
                :disabled="configuringDatabase"
                @click="testDatabaseConnection"
              >
                测试数据库连接
              </el-button>
              <el-button
                v-else-if="!databaseConfigured"
                :disabled="configuringDatabase"
                @click="invalidateDatabaseTest"
              >
                修改连接配置
              </el-button>
            </div>
          </section>

          <section v-show="activeStep === 2" class="install-step" aria-labelledby="install-environment-title">
            <div class="install-step__heading">
              <span><Setting /></span>
              <div>
                <h3 id="install-environment-title">环境检查</h3>
                <p>以下详细结果只有安装口令验证通过后才会返回。</p>
              </div>
            </div>

            <div class="install-status" aria-live="polite">
              <el-alert
                v-if="environmentReady"
                type="success"
                :closable="false"
                title="运行环境已准备完成"
                description="数据库、缓存与持久化存储检查均已通过。"
                show-icon
              />
              <el-alert
                v-else
                type="warning"
                :closable="false"
                title="运行环境尚未就绪"
                description="请根据下方检查结果修复服务器配置，再重新检查。"
                show-icon
              />
            </div>

            <div class="install-checks">
              <article
                v-for="item in checkItems"
                :key="item.key"
                class="install-check"
                :class="{ 'is-ok': item.check.ok, 'is-error': !item.check.ok }"
              >
                <component :is="item.check.ok ? CircleCheckFilled : CircleCloseFilled" aria-hidden="true" />
                <div>
                  <strong>{{ item.label }}</strong>
                  <p>{{ item.check.message }}</p>
                </div>
              </article>
            </div>
            <el-button class="install-step__retry" :loading="checking" @click="checkEnvironment">
              <Refresh />重新执行安全检查
            </el-button>
          </section>

          <section v-show="activeStep === 3" class="install-step" aria-labelledby="install-site-title">
            <div class="install-step__heading">
              <span><Setting /></span>
              <div>
                <h3 id="install-site-title">站点信息</h3>
                <p>这些内容会显示在公开导航首页，稍后仍可在后台修改。</p>
              </div>
            </div>
            <div class="install-form-grid">
              <el-form-item label="站点名称" prop="siteName">
                <el-input v-model="form.siteName" maxlength="50" show-word-limit autocomplete="organization" />
              </el-form-item>
              <el-form-item label="站点简介（可选）" prop="siteDescription">
                <el-input v-model="form.siteDescription" maxlength="255" show-word-limit />
              </el-form-item>
            </div>
          </section>

          <section v-show="activeStep === 4" class="install-step" aria-labelledby="install-admin-title">
            <div class="install-step__heading">
              <span><User /></span>
              <div>
                <h3 id="install-admin-title">创建首位管理员</h3>
                <p>管理员账号用于登录后台，请使用唯一且足够强的密码。</p>
              </div>
            </div>
            <div class="install-form-grid is-two-column">
              <el-form-item label="管理员用户名" prop="username">
                <el-input v-model="form.username" maxlength="32" autocomplete="username">
                  <template #prefix><User /></template>
                </el-input>
              </el-form-item>
              <el-form-item label="管理员昵称" prop="nickname">
                <el-input v-model="form.nickname" maxlength="50" autocomplete="nickname" />
              </el-form-item>
              <el-form-item label="管理员密码" prop="password">
                <el-input v-model="form.password" type="password" show-password autocomplete="new-password">
                  <template #prefix><Lock /></template>
                </el-input>
              </el-form-item>
              <el-form-item label="确认管理员密码" prop="confirmPassword">
                <el-input v-model="form.confirmPassword" type="password" show-password autocomplete="new-password">
                  <template #prefix><Lock /></template>
                </el-input>
              </el-form-item>
            </div>

            <div class="install-password-policy" :class="`is-${passwordPolicy.strength}`" aria-live="polite">
              <div class="install-password-policy__summary">
                <span>密码强度</span>
                <strong>{{ strengthLabel }}</strong>
              </div>
              <div class="install-password-policy__track" aria-hidden="true"><i :style="{ width: strengthWidth }" /></div>
              <ul>
                <li :class="{ 'is-valid': passwordPolicy.lengthValid }">至少 {{ PASSWORD_MIN_LENGTH }} 个字符，且不超过 {{ PASSWORD_MAX_LENGTH }} 个 UTF-8 字节</li>
                <li :class="{ 'is-valid': passwordPolicy.whitespaceFree && form.password.length > 0 }">不包含空格或其他空白字符</li>
                <li :class="{ 'is-valid': passwordPolicy.categoriesValid }">大写、小写、数字、符号至少三类（当前 {{ passwordPolicy.categoryCount }}/4）</li>
                <li :class="{ 'is-valid': passwordPolicy.usernameFree && form.password.length > 0 }">不包含管理员用户名</li>
              </ul>
            </div>
          </section>

          <section v-show="activeStep === 5" class="install-step" aria-labelledby="install-confirm-title">
            <div class="install-step__heading">
              <span><Key /></span>
              <div>
                <h3 id="install-confirm-title">确认并完成安装</h3>
                <p>核对公开信息与管理员身份，确认后将不可再次运行网页安装。</p>
              </div>
            </div>

            <dl class="install-summary">
              <div><dt>站点名称</dt><dd>{{ form.siteName }}</dd></div>
              <div><dt>站点简介</dt><dd>{{ form.siteDescription || '未填写' }}</dd></div>
              <div><dt>管理员用户名</dt><dd>{{ form.username }}</dd></div>
              <div><dt>管理员昵称</dt><dd>{{ form.nickname }}</dd></div>
              <div><dt>数据库</dt><dd>{{ databaseConfigurationLabel }}</dd></div>
            </dl>

            <el-form-item prop="confirmationAccepted" class="install-confirmation-field">
              <el-checkbox v-model="form.confirmationAccepted">
                我已核对以上信息，并知晓安装成功后网页向导将永久关闭。
              </el-checkbox>
            </el-form-item>
          </section>
        </el-form>

        <footer class="install-wizard__actions">
          <el-button
            v-if="activeStep > 0"
            :disabled="testingDatabase || configuringDatabase || checking || submitting"
            @click="previousStep"
          >
            上一步
          </el-button>
          <span v-else />
          <el-button
            v-if="activeStep < 5"
            type="primary"
            :loading="(activeStep === 1 && configuringDatabase) || (activeStep === 2 && checking)"
            :disabled="
              (activeStep === 0 && !canEnterDatabaseStep)
                || (activeStep === 1 && !databaseConfigured && (!databaseCanConfigure || testingDatabase || configuringDatabase))
                || (activeStep === 2 && (!environmentReady || checking))
            "
            @click="nextStep"
          >
            {{
              activeStep === 0
                ? status?.state === 'DATABASE_REQUIRED' ? '继续配置' : '验证并检查'
                : activeStep === 1 && !databaseConfigured ? '应用数据库配置' : '下一步'
            }} <Right />
          </el-button>
          <el-button
            v-else
            type="primary"
            :loading="submitting"
            :disabled="submissionFinished"
            @click="completeInstallation"
          >
            完成安装
          </el-button>
        </footer>
      </section>
    </main>
  </div>
</template>
