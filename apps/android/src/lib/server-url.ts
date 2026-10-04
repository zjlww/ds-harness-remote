import type { PairLink } from '../types'
import { strings as zhCN } from '../locales/i18n'

export function normalizeServerUrl(input: string): string {
  const value = input.trim().replace(/\/+$/, '')
  if (value.length === 0) throw new Error(zhCN.validation.serverRequired)

  const withScheme = /^[a-z][a-z\d+.-]*:\/\//i.test(value) ? value : `https://${value}`
  let url: URL
  try {
    url = new URL(withScheme)
  } catch {
    throw new Error(zhCN.validation.serverInvalid)
  }

  // HTTPS only. A bearer token is sent to this origin on every request, and the app
  // no longer permits cleartext traffic, so accepting http:// here would only produce a
  // confusing runtime failure while inviting token theft on a shared network.
  if (url.protocol !== 'https:') {
    throw new Error(zhCN.validation.httpsRequired)
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error(zhCN.validation.serverPartsForbidden)
  }
  return url.toString().replace(/\/$/, '')
}

export function websocketUrl(baseUrl: string): string {
  const url = new URL(normalizeServerUrl(baseUrl))
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  url.pathname = '/ws/v1/connect'
  return url.toString()
}

export function parsePairLink(url: string): PairLink {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'dshremote:' || parsed.hostname !== 'pair') return {}
    if (parsed.searchParams.get('v') !== '1') return {}
    const server = parsed.searchParams.get('server') ?? undefined
    return server === undefined ? {} : { server }
  } catch {
    return {}
  }
}
