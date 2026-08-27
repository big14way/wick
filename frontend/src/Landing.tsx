import { config } from "./config";

// Product landing. The dashboard lives behind the Launch app button (#app),
// so first time visitors get the story before the tooling.
export function Landing({ epochsSettled, ordersSeen }: { epochsSettled: number; ordersSeen: number }) {
  return (
    <div className="landing">
      <header className="land-mast">
        <div className="wordmark">
          Wick<span className="dot">.</span>
        </div>
        <nav className="land-nav">
          <a href="https://github.com/big14way/wick" target="_blank" rel="noreferrer">
            GitHub
          </a>
          <a className="btn connect" href="#app">
            Launch app
          </a>
        </nav>
      </header>

      <section className="hero">
        <div className="hero-copy">
          <h1>
            Swaps that <span className="hl">cannot be sandwiched</span>
          </h1>
          <p className="hero-sub">
            Wick is a Uniswap v4 hook that settles swaps like a 17th century candle auction. Orders gather while
            the candle burns, a random close block is drawn after the fact, and everything clears at one uniform
            price. There is no deadline to snipe, so there is no sandwich.
          </p>
          <div className="hero-ctas">
            <a className="cta-lg" href="#app">
              Launch app
            </a>
            <a className="cta-ghost" href="https://github.com/big14way/wick" target="_blank" rel="noreferrer">
              Read the code
            </a>
          </div>
          <div className="hero-facts">
            <span>Live on Unichain Sepolia and Base Sepolia</span>
            <span>Close randomness by Chainlink VRF 2.5</span>
            <span>49 passing tests, fuzz and invariants included</span>
          </div>
        </div>
        <div className="hero-candle" aria-hidden="true">
          <div className="candle-stage" style={{ height: 320, width: 130 }}>
            <div className="flame" />
            <div className="wick-thread" />
            <div className="wax-column" style={{ height: 210 }}>
              <div className="scorch-band" style={{ bottom: 0, height: 110 }} />
            </div>
            <div className="candle-base" />
          </div>
        </div>
      </section>

      <section className="land-grid">
        <div className="land-card">
          <h3>The problem</h3>
          <p>
            Sandwich bots tax swappers for hundreds of millions a year. Every fix so far trusts a relay, costs a
            second transaction, or batches to a fixed deadline that bots simply camp. A known closing time is a
            race, and bots win races.
          </p>
        </div>
        <div className="land-card">
          <h3>The fix</h3>
          <p>
            Remove the deadline. The close block is drawn randomly after the window ends and applied
            retroactively. When your order landed, the close did not exist yet. Position in the batch carries no
            edge because every order on a side clears at the same price.
          </p>
        </div>
      </section>

      <section className="land-steps">
        <h2>How a protected swap works</h2>
        <div className="steps-row">
          {[
            ["1", "Swap", "Your input goes into custody. The pool price does not move, you hold an ERC6909 claim."],
            ["2", "Burn", "Orders gather for up to ten blocks while the candle burns. Nobody knows the close."],
            ["3", "Draw", "The window ends, a random close block is drawn by Chainlink VRF and revealed."],
            ["4", "Settle", "Opposing flow nets off the curve, one clearing price per side, redeem pays out."],
          ].map(([n, t, d]) => (
            <div className="step-card" key={n}>
              <div className="step-n">{n}</div>
              <div className="step-t">{t}</div>
              <div className="step-d">{d}</div>
            </div>
          ))}
        </div>
        <p className="land-note">
          In a hurry? The instant lane executes immediately for a volatility priced premium that goes entirely to
          liquidity providers. Toxic flow pays the LPs it used to bleed.
        </p>
      </section>

      <section className="land-receipts">
        <h2>The receipts</h2>
        <div className="receipt-row">
          <div className="receipt">
            <div className="r-label">Textbook sandwich, vanilla pool</div>
            <div className="r-num bad">+7.8757</div>
          </div>
          <div className="receipt">
            <div className="r-label">Same attack against Wick</div>
            <div className="r-num good">-0.3301</div>
          </div>
          <div className="receipt">
            <div className="r-label">Live epochs settled here</div>
            <div className="r-num">{epochsSettled}</div>
          </div>
          <div className="receipt">
            <div className="r-label">Protected orders taken</div>
            <div className="r-num">{ordersSeen}</div>
          </div>
        </div>
        <p className="land-note">
          Attacker profit in tokens from the adversarial simulation in the test suite, identical liquidity on both
          pools. The live numbers read from {config.chainName} as you look at them.
        </p>
      </section>

      <footer className="land-foot">
        <span>Built solo by Gwill for the Atrium UHI10 hookathon on Uniswap v4.</span>
        <a href="#app">Launch app</a>
      </footer>
    </div>
  );
}
