import axios from 'axios'

const api = axios.create({
  baseURL: '/api',
  timeout: 15000,
})

export const verifyToken = (token) =>
  api.get('/verify', { params: { token } })

