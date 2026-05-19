import axios from 'axios'

const api = axios.create({
  baseURL: import.meta.env.VITE_API_URL ?? '/api',
  timeout: 15000,
})

export const verifyToken = (token) =>
  api.get('/verify', { params: { token } })

