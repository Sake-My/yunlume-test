import request, { unwrapApiData } from './request'
import type {
  CompleteInstallationPayload,
  CompleteInstallationResult,
  ConfigureInstallDatabasePayload,
  ConfigureInstallDatabaseResult,
  InstallCheckResult,
  InstallDatabaseConfig,
  InstallDatabaseTestResult,
  InstallStatus,
} from '@/types/install'
import {
  normalizeConfigureInstallDatabaseResult,
  normalizeInstallDatabaseTestResult,
} from '@/utils/installDatabase'
import { normalizeInstallCheckResult, normalizeInstallStatus } from '@/utils/installState'

export async function getInstallStatusApi(): Promise<InstallStatus> {
  const payload = unwrapApiData<unknown>(await request.get('/install/status', { timeout: 2500 }))
  return normalizeInstallStatus(payload)
}

export async function checkInstallationApi(installToken: string): Promise<InstallCheckResult> {
  const payload = unwrapApiData<unknown>(await request.post('/install/check', undefined, {
    timeout: 12000,
    headers: { 'X-Install-Token': installToken },
  }))
  return normalizeInstallCheckResult(payload)
}

export async function testInstallDatabaseApi(
  installToken: string,
  database: InstallDatabaseConfig,
): Promise<InstallDatabaseTestResult> {
  const payload = unwrapApiData<unknown>(await request.post('/install/database/test', database, {
    timeout: 20000,
    headers: { 'X-Install-Token': installToken },
  }))
  return normalizeInstallDatabaseTestResult(payload)
}

export async function configureInstallDatabaseApi(
  installToken: string,
  payload: ConfigureInstallDatabasePayload,
): Promise<ConfigureInstallDatabaseResult> {
  const response = unwrapApiData<unknown>(await request.post('/install/database/configure', payload, {
    timeout: 90000,
    headers: { 'X-Install-Token': installToken },
  }))
  return normalizeConfigureInstallDatabaseResult(response)
}

export async function completeInstallationApi(
  installToken: string,
  payload: CompleteInstallationPayload,
): Promise<CompleteInstallationResult> {
  return unwrapApiData<CompleteInstallationResult>(await request.post('/install/complete', payload, {
    timeout: 20000,
    headers: { 'X-Install-Token': installToken },
  }))
}
