import type { OnyxApi } from './index'

declare global {
  interface Window {
    onyx: OnyxApi
  }
}

export {}
