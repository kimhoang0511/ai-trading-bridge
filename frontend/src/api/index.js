import axios from 'axios'

const api = axios.create({ baseURL: '/api' })

export const verifyToken = (token) =>
  api.get('/verify', { params: { token } })

