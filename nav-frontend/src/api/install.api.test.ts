import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { CompleteInstallationPayload } from '@/types/install'

const requestMocks = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
}))

vi.mock('./request', () => ({
  default: requestMocks,
  unwrapApiData: (response: { data: unknown }) => response.data,
}))

import {
  checkInstallationApi,
  completeInstallationApi,
  configureInstallDatabaseApi,
  getInstallStatusApi,
  testInstallDatabaseApi,
} from './install.api'

describe('installation API security contract', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('uses a short status timeout so a backend outage does not block public routing', async () => {
    const status = {
      state: 'UNKNOWN',
      installationRequired: false,
      webInstallEnabled: false,
      ready: false,
    }
    requestMocks.get.mockResolvedValue({ data: status })

    await expect(getInstallStatusApi()).resolves.toEqual(status)
    expect(requestMocks.get).toHaveBeenCalledWith('/install/status', { timeout: 2500 })
  })

  it('sends the installation token only in the protected check header', async () => {
    const result = {
      ready: true,
      checks: {
        database: { ok: true, message: 'ok' },
        schema: { ok: true, message: 'ok' },
        siteConfig: { ok: true, message: 'ok' },
        upload: { ok: true, message: 'ok' },
        redis: { ok: true, message: 'ok' },
      },
    }
    requestMocks.post.mockResolvedValue({ data: result })

    await expect(checkInstallationApi('secret-token')).resolves.toEqual(result)
    expect(requestMocks.post).toHaveBeenCalledWith('/install/check', undefined, {
      timeout: 12000,
      headers: { 'X-Install-Token': 'secret-token' },
    })
  })

  it('keeps the installation token out of the completion body', async () => {
    const payload: CompleteInstallationPayload = {
      siteName: 'iLinks',
      siteDescription: 'Navigation',
      username: 'admin',
      nickname: '管理员',
      password: 'Example!Pass2026',
      confirmPassword: 'Example!Pass2026',
    }
    requestMocks.post.mockResolvedValue({ data: { installed: true } })

    await expect(completeInstallationApi('secret-token', payload)).resolves.toEqual({ installed: true })
    expect(requestMocks.post).toHaveBeenCalledWith('/install/complete', payload, {
      timeout: 20000,
      headers: { 'X-Install-Token': 'secret-token' },
    })
    expect(payload).not.toHaveProperty('installToken')
  })

  it('submits external database credentials only to the ticket-producing test endpoint', async () => {
    const ticket = 'a'.repeat(64)
    requestMocks.post.mockResolvedValue({
      data: {
        ok: true,
        connectionTicket: ticket,
        expiresAt: '2026-08-15T12:05:00Z',
        schemaState: 'EMPTY',
        requiresInitialization: true,
      },
    })
    const database = {
      host: 'db.example.com',
      port: 5432,
      database: 'navigation',
      username: 'navigation_app',
      password: 'database-secret',
      sslMode: 'VERIFY_FULL' as const,
      caCertificatePem: '-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----',
    }

    await expect(testInstallDatabaseApi('install-secret', database)).resolves.toMatchObject({
      connectionTicket: ticket,
      schemaState: 'EMPTY',
    })
    expect(requestMocks.post).toHaveBeenCalledWith('/install/database/test', database, {
      timeout: 20000,
      headers: { 'X-Install-Token': 'install-secret' },
    })
  })

  it('consumes only the one-time database ticket when applying configuration', async () => {
    const payload = {
      connectionTicket: 'b'.repeat(64),
      initializeSchema: true,
    }
    requestMocks.post.mockResolvedValue({
      data: {
        configured: true,
        initialized: true,
        installed: false,
        restartRequired: true,
      },
    })

    await expect(configureInstallDatabaseApi('install-secret', payload)).resolves.toEqual({
      configured: true,
      initialized: true,
      installed: false,
      restartRequired: true,
    })
    expect(requestMocks.post).toHaveBeenCalledWith('/install/database/configure', payload, {
      timeout: 90000,
      headers: { 'X-Install-Token': 'install-secret' },
    })
    expect(payload).not.toHaveProperty('password')
  })
})
