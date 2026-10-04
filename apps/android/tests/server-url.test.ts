import { describe, expect, it } from 'vitest'
import { normalizeServerUrl, parsePairLink, websocketUrl } from '../src/lib/server-url'

describe('server URL handling', () => {
  it('normalizes secure server and websocket URLs', () => {
    expect(normalizeServerUrl('remote.example.com/')).toBe('https://remote.example.com')
    expect(websocketUrl('https://remote.example.com')).toBe('wss://remote.example.com/ws/v1/connect')
  })

  it('rejects cleartext for every host, including LAN and emulator addresses', () => {
    // The app no longer permits cleartext traffic at all, so accepting these URLs
    // here would only defer the failure to the network layer while risking token theft.
    expect(() => normalizeServerUrl('http://10.0.2.2:8080')).toThrow(/HTTPS/)
    expect(() => normalizeServerUrl('http://remote.example.com')).toThrow(/HTTPS/)
    expect(() => normalizeServerUrl('http://8.8.8.8')).toThrow(/HTTPS/)
    expect(() => normalizeServerUrl('http://192.168.31.9:8090')).toThrow(/HTTPS/)
    expect(() => normalizeServerUrl('http://10.1.2.3:8080')).toThrow(/HTTPS/)
    expect(() => normalizeServerUrl('http://172.20.0.2:8090')).toThrow(/HTTPS/)
    expect(() => normalizeServerUrl('http://100.64.0.3:8090')).toThrow(/HTTPS/)
    expect(() => normalizeServerUrl('http://169.254.1.1:8090')).toThrow(/HTTPS/)
  })

  it('treats a bare host as https and keeps the ws scheme in step', () => {
    expect(normalizeServerUrl('10.1.2.3:8080')).toBe('https://10.1.2.3:8080')
    expect(websocketUrl('https://192.168.31.9:8090')).toBe('wss://192.168.31.9:8090/ws/v1/connect')
  })

  it('parses server deep links without pairing codes', () => {
    expect(parsePairLink('dshremote://pair?v=1&server=https%3A%2F%2Fremote.example.com')).toEqual({
      server: 'https://remote.example.com',
    })
    expect(parsePairLink('dshremote://pair?v=2&server=https%3A%2F%2Fremote.example.com')).toEqual({})
    expect(parsePairLink('https://example.com/not-a-pair-link')).toEqual({})
  })
})
