/// <reference types="vite/client" />

import type { OnyxApi } from '../../preload/index'

declare global {
  interface Window {
    onyx: OnyxApi
  }
}

declare module '*?worker' {
  const workerConstructor: new () => Worker
  export default workerConstructor
}

export {}
