import { useState, useEffect, useRef, useCallback, useMemo, memo } from 'react'
import { useSearchParams } from 'react-router-dom'
import ReactMarkdown from 'react-markdown'
import { QRCodeSVG } from 'qrcode.react'
import { verifyToken } from '../api'

const CACHE_PREFIX = 'ai_bridge_session_'

// ── Styles (defined outside component — no re-creation on each render) ────────
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
  qrBtn: {
    marginLeft: 8, width: 32, height: 32, borderRadius: 8,
    background: 'transparent', border: '1px solid #e2e8f0',
    cursor: 'pointer', display: 'flex', alignItems: 'center',
    justifyContent: 'center', color: '#64748b', flexShrink: 0,
    transition: 'background .15s',
  },
  clearBtn: {
    width: 32, height: 32, borderRadius: 8,
    background: 'transparent', border: '1px solid #fecdd3',
    cursor: 'pointer', display: 'flex', alignItems: 'center',
    justifyContent: 'center', color: '#f87171', flexShrink: 0,
    transition: 'background .15s',
  },
  qrOverlay: {
    position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.5)',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    zIndex: 1000,
  },
  qrModal: {
    background: '#fff', borderRadius: 20, padding: '28px 32px',
    display: 'flex', flexDirection: 'column', alignItems: 'center',
    gap: 16, boxShadow: '0 8px 40px rgba(0,0,0,0.18)',
    maxWidth: 320, width: '90%',
  },
  qrTitle: { fontSize: 15, fontWeight: 600, color: '#1e293b' },
  qrSub:   { fontSize: 12, color: '#94a3b8', textAlign: 'center', lineHeight: 1.5 },
  qrClose: {
    marginTop: 4, padding: '8px 28px', borderRadius: 10,
    background: '#2563eb', border: 'none', color: '#fff',
    fontSize: 14, fontWeight: 600, cursor: 'pointer',
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

// ── Memoized message bubble — only re-renders when content changes ────────────
const MessageBubble = memo(function MessageBubble({ m }) {
  return (
    <div>
      <div style={s.role(m.role)}>
        {m.role === 'user' ? 'You' : 'AI Assistant'}
      </div>
      <div style={s.bubble(m.role)}>
        <MarkdownSafe>{m.content}</MarkdownSafe>
      </div>
    </div>
  )
})

// ── ReactMarkdown with error boundary ────────────────────────────────────────
function MarkdownSafe({ children }) {
  try {
    return <ReactMarkdown>{children}</ReactMarkdown>
  } catch {
    return <span style={{ whiteSpace: 'pre-wrap' }}>{children}</span>
  }
}

// ── Memoized QR code — chatUrl never changes after mount ─────────────────────
const QrCode = memo(function QrCode({ url }) {
  return <QRCodeSVG value={url} size={200} level="M" />
})

function getGreeting() {
  const lang = (navigator.language || 'en').toLowerCase()
  const l = lang.slice(0, 2)
  const greetings = {
    vi: ['👋 Xin chào! Tôi là **AI Strategy Manager** của bạn.',
         'Tôi có thể giúp bạn **thêm, sửa, xóa** các Trading Strategy trên MT4.',
         '*Ví dụ: "Thêm strategy mua EURUSD khi MA20 cắt lên MA50"*'],
    zh: ['👋 你好！我是你的 **AI Strategy Manager**。',
         '我可以帮你在 MT4 上**添加、修改、删除**交易策略。',
         '*例如："当MA20上穿MA50时买入EURUSD"*'],
    ja: ['👋 こんにちは！**AI Strategy Manager** です。',
         'MT4 の取引戦略を**追加・変更・削除**するお手伝いをします。',
         '*例：「MA20がMA50を上抜けたらEURUSDを買う」*'],
    ko: ['👋 안녕하세요! **AI Strategy Manager**입니다.',
         'MT4에서 트레이딩 전략을 **추가·수정·삭제**해 드립니다.',
         '*예: "MA20이 MA50을 상향 돌파할 때 EURUSD 매수"*'],
    es: ['👋 ¡Hola! Soy tu **AI Strategy Manager**.',
         'Puedo ayudarte a **añadir, editar y eliminar** estrategias en MT4.',
         '*Ejemplo: "Comprar EURUSD cuando MA20 cruce sobre MA50"*'],
    fr: ['👋 Bonjour ! Je suis votre **AI Strategy Manager**.',
         'Je peux vous aider à **ajouter, modifier et supprimer** des stratégies sur MT4.',
         '*Exemple : "Acheter EURUSD quand MA20 croise MA50 à la hausse"*'],
    de: ['👋 Hallo! Ich bin Ihr **AI Strategy Manager**.',
         'Ich helfe Ihnen beim **Hinzufügen, Bearbeiten und Löschen** von Strategien in MT4.',
         '*Beispiel: „EURUSD kaufen, wenn MA20 MA50 nach oben kreuzt"*'],
    pt: ['👋 Olá! Sou o seu **AI Strategy Manager**.',
         'Posso ajudá-lo a **adicionar, editar e remover** estratégias no MT4.',
         '*Exemplo: "Comprar EURUSD quando MA20 cruzar acima de MA50"*'],
    th: ['👋 สวัสดี! ฉันคือ **AI Strategy Manager** ของคุณ',
         'ฉันช่วยคุณ**เพิ่ม แก้ไข และลบ**กลยุทธ์การเทรดบน MT4 ได้',
         '*ตัวอย่าง: "ซื้อ EURUSD เมื่อ MA20 ตัดขึ้นเหนือ MA50"*'],
    id: ['👋 Halo! Saya adalah **AI Strategy Manager** Anda.',
         'Saya dapat membantu Anda **menambah, mengedit, dan menghapus** strategi di MT4.',
         '*Contoh: "Beli EURUSD ketika MA20 memotong MA50 ke atas"*'],
    ar: ['👋 مرحباً! أنا **AI Strategy Manager** الخاص بك.',
         'يمكنني مساعدتك في **إضافة وتعديل وحذف** استراتيجيات التداول على MT4.',
         '*مثال: "اشتر EURUSD عندما يتقاطع MA20 فوق MA50"*'],
    ru: ['👋 Привет! Я ваш **AI Strategy Manager**.',
         'Я помогу вам **добавлять, изменять и удалять** торговые стратегии в MT4.',
         '*Пример: «Купить EURUSD, когда MA20 пересечёт MA50 снизу вверх»*'],
  }
  const t = greetings[l] || [
    '👋 Hello! I\'m your **AI Strategy Manager**.',
    'I can help you **add, update and delete** trading strategies on MT4.',
    '*Example: "Buy EURUSD when MA20 crosses above MA50"*',
  ]
  return t.join('\n\n')
}

// ── Chat URL is stable — compute once at module level ────────────────────────
const CHAT_URL = window.location.href

export default function Chat() {
  const [params]   = useSearchParams()
  const token      = params.get('token') || ''
  const cacheKey   = CACHE_PREFIX + token

  const [status, setStatus]       = useState('verifying')
  const [userInfo, setUserInfo]   = useState(null)
  const [messages, setMessages]   = useState([])
  const [input, setInput]         = useState('')
  const [loading, setLoading]     = useState(false)
  const [error, setError]         = useState('')
  const [accInput, setAccInput]   = useState('')
  const [accError, setAccError]   = useState('')
  const [wsOnline, setWsOnline]   = useState(false)
  const [showQr, setShowQr]       = useState(false)
  const bottomRef                 = useRef(null)
  const wsRef                     = useRef(null)
  const scrollRafRef              = useRef(null)

  // ── Verify token on mount ────────────────────────────────────────────
  useEffect(() => {
    if (!token) { setStatus('error'); setError('No token provided in URL.'); return }

    verifyToken(token)
      .then(r => {
        setUserInfo(r.data)
        let cached
        try { cached = localStorage.getItem(cacheKey) } catch { cached = null }
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

  // ── WebSocket connection ─────────────────────────────────────────────
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
        } else if (data.event === 'history_cleared') {
          setMessages([])
          setLoading(false)
        }
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

  const enterChat = useCallback((info) => {
    setStatus('ok')
    const activeDate = info.active_date
      ? new Date(info.active_date).toLocaleDateString('en-GB')
      : null
    setMessages([{
      role: 'assistant',
      content: [
        getGreeting(),
        ``,
        `Account: **${info.account_number}** | Server: **${info.server_broker}** | License: **${info.license_type}**${activeDate ? ` | Active: **${activeDate}**` : ''}`,
      ].join('\n'),
    }])
  }, [])

  // ── Account number confirmation ──────────────────────────────────────
  const confirmAccount = useCallback(() => {
    if (String(accInput.trim()) === String(userInfo.account_number)) {
      try { localStorage.setItem(cacheKey, String(userInfo.account_number)) } catch { }
      enterChat(userInfo)
    } else {
      setAccError('Incorrect account number. Please try again.')
    }
  }, [accInput, userInfo, cacheKey, enterChat])

  const onAccKey = useCallback((e) => {
    if (e.key === 'Enter') confirmAccount()
  }, [confirmAccount])

  // ── Auto-scroll — debounced via requestAnimationFrame ───────────────
  useEffect(() => {
    if (scrollRafRef.current) cancelAnimationFrame(scrollRafRef.current)
    scrollRafRef.current = requestAnimationFrame(() => {
      bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
    })
    return () => {
      if (scrollRafRef.current) cancelAnimationFrame(scrollRafRef.current)
    }
  }, [messages, loading])

  // ── Send message via WebSocket ───────────────────────────────────────
  const send = useCallback(() => {
    const text = input.trim()
    if (!text || loading) return

    const ws = wsRef.current
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      setMessages(m => [...m, {
        role: 'assistant',
        content: '⚠️ Connection lost. Please refresh the page.',
      }])
      return
    }

    setInput('')
    setMessages(m => [...m, { role: 'user', content: text }])
    setLoading(true)
    ws.send(JSON.stringify({ event: 'chat_message', message: text }))
  }, [input, loading])

  const onKey = useCallback((e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
  }, [send])

  const onInputChange = useCallback((e) => setInput(e.target.value), [])
  const openQr  = useCallback(() => setShowQr(true),  [])
  const closeQr = useCallback(() => setShowQr(false), [])

  const clearHistory = useCallback(() => {
    const ws = wsRef.current
    if (!ws || ws.readyState !== WebSocket.OPEN) return
    ws.send(JSON.stringify({ event: 'clear_history' }))
  }, [])

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

      {/* QR Modal */}
      {showQr && (
        <div style={s.qrOverlay} onClick={closeQr}>
          <div style={s.qrModal} onClick={e => e.stopPropagation()}>
            <div style={s.qrTitle}>📱 Open on Mobile</div>
            <QrCode url={CHAT_URL} />
            <div style={s.qrSub}>Scan this QR code to open the chat on your phone</div>
            <button style={s.qrClose} onClick={closeQr}>Close</button>
          </div>
        </div>
      )}

      <div style={s.root}>
        {/* Header */}
        <div style={s.header}>
          <div style={s.dot(wsOnline)} />
          <span style={s.title}>AI Strategy Manager</span>
          <span style={s.sub}>
            #{userInfo?.account_number} · {userInfo?.license_type}
          </span>
          <button style={s.qrBtn} onClick={openQr} title="Open on mobile">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <rect x="3" y="3" width="7" height="7" rx="1"/>
              <rect x="14" y="3" width="7" height="7" rx="1"/>
              <rect x="3" y="14" width="7" height="7" rx="1"/>
              <rect x="14" y="14" width="3" height="3" rx="0.5"/>
              <rect x="19" y="14" width="2" height="2" rx="0.5"/>
              <rect x="14" y="19" width="2" height="2" rx="0.5"/>
              <rect x="18" y="18" width="3" height="3" rx="0.5"/>
            </svg>
          </button>
          <span style={{ fontSize: 11, color: '#94a3b8', whiteSpace: 'nowrap' }}>
            Open on mobile
          </span>
          <button style={s.clearBtn} onClick={clearHistory} title="Clear conversation history">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <polyline points="3 6 5 6 21 6"/>
              <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
              <path d="M10 11v6M14 11v6"/>
              <path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/>
            </svg>
          </button>
        </div>

        {/* Messages */}
        <div style={s.messages}>
          {messages.map((m, i) => (
            <MessageBubble key={i} m={m} />
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
            onChange={onInputChange}
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
