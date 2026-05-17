import { useState, useEffect, useRef } from 'react'
import { useSearchParams } from 'react-router-dom'
import ReactMarkdown from 'react-markdown'
import { verifyToken } from '../api'

const CACHE_PREFIX = 'ai_bridge_session_'

const s = {
  root: {
    display: 'flex', flexDirection: 'column', height: '100vh',
    background: '#f5f7fa', color: '#1a1a2e',
  },
  header: {
    padding: '12px 20px', background: '#ffffff',
    borderBottom: '1px solid #e2e8f0',
    display: 'flex', alignItems: 'center', gap: 12,
    boxShadow: '0 1px 4px rgba(0,0,0,0.06)',
  },
  dot: (online) => ({
    width: 8, height: 8, borderRadius: '50%',
    background: online ? '#22c55e' : '#ef4444',
  }),
  title: { fontSize: 16, fontWeight: 600, color: '#1e293b' },
  sub:   { fontSize: 12, color: '#94a3b8', marginLeft: 'auto' },
  messages: {
    flex: 1, overflowY: 'auto', padding: '20px 16px',
    display: 'flex', flexDirection: 'column', gap: 12,
  },
  bubble: (role) => ({
    maxWidth: '75%',
    alignSelf: role === 'user' ? 'flex-end' : 'flex-start',
    background: role === 'user' ? '#2563eb' : '#ffffff',
    color: role === 'user' ? '#ffffff' : '#1e293b',
    border: role === 'user' ? 'none' : '1px solid #e2e8f0',
    borderRadius: role === 'user' ? '18px 18px 4px 18px' : '18px 18px 18px 4px',
    padding: '10px 14px', fontSize: 14, lineHeight: 1.6,
    boxShadow: '0 1px 3px rgba(0,0,0,0.07)',
  }),
  role: (role) => ({
    fontSize: 11, color: '#94a3b8', marginBottom: 4,
    textAlign: role === 'user' ? 'right' : 'left',
  }),
  typing: {
    alignSelf: 'flex-start', background: '#ffffff',
    border: '1px solid #e2e8f0', borderRadius: '18px 18px 18px 4px',
    padding: '10px 16px', display: 'flex', gap: 4,
    boxShadow: '0 1px 3px rgba(0,0,0,0.07)',
  },
  typingDot: (i) => ({
    width: 6, height: 6, borderRadius: '50%', background: '#94a3b8',
    animation: `bounce 1s ${i * 0.15}s infinite`,
  }),
  inputRow: {
    padding: '12px 16px', background: '#ffffff',
    borderTop: '1px solid #e2e8f0',
    display: 'flex', gap: 8,
    boxShadow: '0 -1px 4px rgba(0,0,0,0.04)',
  },
  input: {
    flex: 1, background: '#f8fafc', border: '1px solid #e2e8f0',
    borderRadius: 24, padding: '10px 18px', color: '#1e293b',
    fontSize: 14, outline: 'none', resize: 'none',
    maxHeight: 120, overflowY: 'auto', fontFamily: 'inherit',
  },
  sendBtn: (disabled) => ({
    width: 44, height: 44, borderRadius: '50%',
    background: disabled ? '#bfdbfe' : '#2563eb',
    border: 'none', cursor: disabled ? 'not-allowed' : 'pointer',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    flexShrink: 0, transition: 'background .2s',
  }),
  center: {
    display: 'flex', flexDirection: 'column',
    alignItems: 'center', justifyContent: 'center',
    height: '100vh', gap: 12, background: '#f5f7fa', color: '#64748b',
  },
  card: {
    padding: '32px 40px', background: '#ffffff',
    border: '1px solid #e2e8f0', borderRadius: 16,
    textAlign: 'center', maxWidth: 380, width: '90%',
    boxShadow: '0 4px 20px rgba(0,0,0,0.08)',
  },
  errorBox: {
    padding: '20px 32px', background: '#fff1f2',
    border: '1px solid #fecdd3', borderRadius: 12,
    color: '#e11d48', textAlign: 'center', maxWidth: 360,
  },
  confirmInput: {
    width: '100%', boxSizing: 'border-box',
    background: '#f8fafc', border: '1px solid #e2e8f0',
    borderRadius: 8, padding: '10px 14px',
    color: '#1e293b', fontSize: 15, outline: 'none',
    marginTop: 16, textAlign: 'center', letterSpacing: 2,
  },
  confirmBtn: (disabled) => ({
    marginTop: 12, width: '100%',
    padding: '10px 0', borderRadius: 8,
    background: disabled ? '#bfdbfe' : '#2563eb',
    border: 'none', color: '#fff', fontSize: 14,
    cursor: disabled ? 'not-allowed' : 'pointer',
    fontWeight: 600, transition: 'background .2s',
  }),
  confirmErr: {
    marginTop: 8, fontSize: 12, color: '#e11d48',
  },
}

const BOUNCE_STYLE = `
  @keyframes bounce {
    0%,80%,100% { transform: translateY(0) }
    40%          { transform: translateY(-6px) }
  }
  pre  { background:#f1f5f9; padding:10px; border-radius:6px; overflow:auto; border:1px solid #e2e8f0; }
  code { font-family: monospace; font-size:13px; color:#0f172a; }
  p    { margin: 4px 0; }
  ul, ol { margin: 4px 0; padding-left: 18px; }
  li   { margin: 2px 0; }
  *    { box-sizing: border-box; }
`

export default function Chat() {
  const [params]   = useSearchParams()
  const token      = params.get('token') || ''
  const cacheKey   = CACHE_PREFIX + token

  // status: verifying | confirm | ok | error
  const [status, setStatus]       = useState('verifying')
  const [userInfo, setUserInfo]   = useState(null)
  const [messages, setMessages]   = useState([])
  const [input, setInput]         = useState('')
  const [loading, setLoading]     = useState(false)
  const [error, setError]         = useState('')
  const [accInput, setAccInput]   = useState('')
  const [accError, setAccError]   = useState('')
  const [wsOnline, setWsOnline]   = useState(false)
  const bottomRef                 = useRef(null)
  const wsRef                     = useRef(null)

  // ── Verify token on mount ────────────────────────────────────────────
  useEffect(() => {
    if (!token) { setStatus('error'); setError('No token provided in URL.'); return }

    verifyToken(token)
      .then(r => {
        setUserInfo(r.data)
        const cached = localStorage.getItem(cacheKey)
        if (cached === String(r.data.account_number)) {
          enterChat(r.data)
        } else {
          setStatus('confirm')
        }
      })
      .catch(() => {
        setStatus('error')
        setError('Invalid or expired token.')
      })
  }, [token])

  // ── WebSocket connection (opened when status becomes 'ok') ───────────
  useEffect(() => {
    if (status !== 'ok' || !userInfo) return

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const ws = new WebSocket(
      `${protocol}//${window.location.host}/ws/chat/${userInfo.account_number}?token=${token}`
    )
    wsRef.current = ws

    ws.onopen = () => setWsOnline(true)

    ws.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data)
        if (data.event === 'chat_reply') {
          setMessages(m => [...m, { role: 'assistant', content: data.reply }])
          setLoading(false)
        }
        // strategy_list / strategy_update / strategy_delete could update a sidebar in future
      } catch {
        // ignore malformed frames
      }
    }

    ws.onerror = () => {
      setWsOnline(false)
      setLoading(false)
      setMessages(m => [...m, {
        role: 'assistant',
        content: '⚠️ WebSocket error. Please refresh the page.',
      }])
    }

    ws.onclose = () => {
      setWsOnline(false)
      setLoading(false)
      wsRef.current = null
    }

    return () => {
      ws.close()
      wsRef.current = null
    }
  }, [status, userInfo])

  const enterChat = (info) => {
    setStatus('ok')
    const activeDate = info.active_date
      ? new Date(info.active_date).toLocaleDateString('en-GB')
      : null
    setMessages([{
      role: 'assistant',
      content: [
        `👋 Xin chào! Tôi là **AI Strategy Manager** của bạn.`,
        ``,
        `Account: **${info.account_number}** | Server: **${info.server_broker}** | License: **${info.license_type}**${activeDate ? ` | Active: **${activeDate}**` : ''}`,
        ``,
        `Tôi có thể giúp bạn **thêm, sửa, xóa** các Trading Strategy trên MT4.`,
        `Ví dụ: *"Thêm strategy mua EURUSD khi MA20 cắt lên MA50"*`,
      ].join('\n'),
    }])
  }

  // ── Account number confirmation ──────────────────────────────────────
  const confirmAccount = () => {
    if (String(accInput.trim()) === String(userInfo.account_number)) {
      localStorage.setItem(cacheKey, String(userInfo.account_number))
      enterChat(userInfo)
    } else {
      setAccError('Incorrect account number. Please try again.')
    }
  }

  const onAccKey = (e) => {
    if (e.key === 'Enter') confirmAccount()
  }

  // ── Auto-scroll ──────────────────────────────────────────────────────
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, loading])

  // ── Send message via WebSocket ───────────────────────────────────────
  const send = () => {
    const text = input.trim()
    if (!text || loading) return

    const ws = wsRef.current
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      setMessages(m => [...m, {
        role: 'assistant',
        content: '⚠️ Mất kết nối. Vui lòng tải lại trang.',
      }])
      return
    }

    setInput('')
    setMessages(m => [...m, { role: 'user', content: text }])
    setLoading(true)
    ws.send(JSON.stringify({ event: 'chat_message', message: text }))
  }

  const onKey = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
  }

  // ── States ───────────────────────────────────────────────────────────
  if (status === 'verifying') return (
    <div style={s.center}><div>Verifying access...</div></div>
  )

  if (status === 'error') return (
    <div style={s.center}>
      <div style={s.errorBox}>
        <div style={{ fontSize: 32, marginBottom: 8 }}>⚠️</div>
        <div style={{ fontWeight: 600, marginBottom: 4 }}>Access Denied</div>
        <div style={{ fontSize: 13 }}>{error}</div>
      </div>
    </div>
  )

  if (status === 'confirm') return (
    <div style={s.center}>
      <style>{BOUNCE_STYLE}</style>
      <div style={s.card}>
        <div style={{ fontSize: 28, marginBottom: 8 }}>🔐</div>
        <div style={{ fontSize: 17, fontWeight: 600, color: '#f0f0f0', marginBottom: 4 }}>
          Verify Your Account
        </div>
        <div style={{ fontSize: 13, color: '#666' }}>
          Enter your MT4 account number to continue.
        </div>
        <input
          style={s.confirmInput}
          type="number"
          placeholder="Account number"
          value={accInput}
          onChange={e => { setAccInput(e.target.value); setAccError('') }}
          onKeyDown={onAccKey}
          autoFocus
        />
        {accError && <div style={s.confirmErr}>{accError}</div>}
        <button
          style={s.confirmBtn(!accInput.trim())}
          onClick={confirmAccount}
          disabled={!accInput.trim()}
        >
          Confirm
        </button>
      </div>
    </div>
  )

  const disabled = !input.trim() || loading

  return (
    <>
      <style>{BOUNCE_STYLE}</style>
      <div style={s.root}>
        {/* Header */}
        <div style={s.header}>
          <div style={s.dot(wsOnline)} />
          <span style={s.title}>AI Strategy Manager</span>
          <span style={s.sub}>
            #{userInfo?.account_number} · {userInfo?.license_type}
          </span>
        </div>

        {/* Messages */}
        <div style={s.messages}>
          {messages.map((m, i) => (
            <div key={i}>
              <div style={s.role(m.role)}>
                {m.role === 'user' ? 'You' : 'AI Assistant'}
              </div>
              <div style={s.bubble(m.role)}>
                <ReactMarkdown>{m.content}</ReactMarkdown>
              </div>
            </div>
          ))}

          {loading && (
            <div>
              <div style={s.role('assistant')}>AI Assistant</div>
              <div style={s.typing}>
                {[0,1,2].map(i => <div key={i} style={s.typingDot(i)} />)}
              </div>
            </div>
          )}
          <div ref={bottomRef} />
        </div>

        {/* Input */}
        <div style={s.inputRow}>
          <textarea
            style={s.input}
            rows={1}
            placeholder="Thêm / sửa / xóa strategy... (VD: thêm strategy mua EURUSD khi RSI < 30)"
            value={input}
            onChange={e => setInput(e.target.value)}
            onKeyDown={onKey}
          />
          <button style={s.sendBtn(disabled)} onClick={send} disabled={disabled}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2">
              <line x1="22" y1="2" x2="11" y2="13"/>
              <polygon points="22 2 15 22 11 13 2 9 22 2"/>
            </svg>
          </button>
        </div>
      </div>
    </>
  )
}
