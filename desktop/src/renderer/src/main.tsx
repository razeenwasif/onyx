import React from 'react'
import { createRoot } from 'react-dom/client'
import './styles/app.css'
import 'katex/dist/katex.min.css'
import { App } from './App'

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
