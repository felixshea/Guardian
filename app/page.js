export default function Home() {
  return (
    <main style={{
      minHeight: "100vh",
      background: "linear-gradient(135deg, #0f172a, #020617)",
      color: "white",
      display: "flex",
      flexDirection: "column",
      justifyContent: "center",
      alignItems: "center",
      fontFamily: "sans-serif",
      textAlign: "center",
      padding: 20
    }}>
      <h1 style={{fontSize: 40, marginBottom: 20}}>
        🛡 Guardian — AI Onchain Portfolio Protector
      </h1>

      <p style={{maxWidth: 500, opacity: 0.8}}>
        Automated price alerts, wallet monitoring,
        trading automation & risk management on Base.
      </p>

      <div style={{marginTop: 30}}>
        <a href="https://github.com/felixshea/Guardian"
          style={{
            background: "#2563eb",
            padding: "12px 24px",
            borderRadius: 8,
            textDecoration: "none",
            color: "white",
            fontWeight: "bold"
          }}>
          View GitHub
        </a>
      </div>
    </main>
  )
}
