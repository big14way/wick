// The signature element. A wax candle burns down across the epoch window.
// Nobody knows where inside the scorch band it will die. After the reveal,
// a burn mark shows the block where the candle went out.

type Props = {
  phase: number; // 0 open, 1 drawing, 2 revealed
  epochStart: bigint;
  minSpan: bigint;
  maxSpan: bigint;
  currentBlock: bigint;
  revealedClose: bigint;
};

const STAGE_H = 260;

export function Candle({ phase, epochStart, minSpan, maxSpan, currentBlock, revealedClose }: Props) {
  // A window that ran out with no orders waits for the next order to relight,
  // so it renders like the idle state rather than a burnt out stub.
  const expired = epochStart !== 0n && phase === 0 && currentBlock > epochStart + maxSpan - 1n;
  const idle = epochStart === 0n || expired;
  const windowLast = idle ? 0n : epochStart + maxSpan - 1n;
  const earliestClose = idle ? 0n : epochStart + minSpan - 1n;

  // Fraction of the window already burned, 0 at epochStart, 1 at windowLast.
  let burned = 0;
  if (!idle && maxSpan > 0n) {
    const elapsed = currentBlock >= epochStart ? Number(currentBlock - epochStart) : 0;
    burned = Math.min(elapsed / Number(maxSpan), 1);
  }
  if (phase !== 0) burned = 1;

  const waxH = Math.max(Math.round(STAGE_H * (1 - burned)), 14);

  // Scorch band covers the possible close range, measured from the base up.
  // Block b maps to remaining height STAGE_H * (1 - (b - epochStart + 1) / maxSpan).
  const heightAt = (b: bigint) =>
    idle ? 0 : Math.max(Math.round(STAGE_H * (1 - Number(b - epochStart + 1n) / Number(maxSpan))), 0);

  const bandTop = heightAt(earliestClose); // taller edge, earliest possible death
  const bandBottom = heightAt(windowLast); // shorter edge, latest possible death
  const bandVisible = !idle && phase === 0;

  const markVisible = phase === 2 && revealedClose >= epochStart;
  const markBottom = markVisible ? heightAt(revealedClose) : 0;

  const flameOut = phase !== 0;

  const steps = ["Waiting", "Burning", "Drawing", "Revealed"];
  const activeStep = idle ? 0 : phase === 0 ? 1 : phase === 1 ? 2 : 3;

  return (
    <div className="candle-scene">
      <div className="steps" aria-label="Candle lifecycle">
        {steps.map((s, i) => (
          <span key={s} className={i < activeStep ? "step done" : i === activeStep ? "step now" : "step"}>
            {s}
          </span>
        ))}
      </div>
      <div className="candle-stage" aria-hidden="true">
        <div className={flameOut ? "flame out" : "flame"} />
        <div className="wick-thread" />
        <div className="wax-column" style={{ height: waxH }}>
          {bandVisible && (
            <div
              className="scorch-band"
              style={{
                bottom: Math.min(bandBottom, waxH),
                height: Math.max(Math.min(bandTop, waxH) - Math.min(bandBottom, waxH), 4),
              }}
            />
          )}
          {markVisible && <div className="burn-mark" style={{ bottom: Math.min(markBottom, waxH - 3) }} />}
        </div>
        <div className="candle-base" />
      </div>
      <div className="candle-caption">
        {expired && "The last window passed empty. The next protected order relights the candle."}
        {idle && !expired && "No orders yet. The candle lights when the first protected order lands."}
        {!idle && phase === 0 && "Burning. The candle dies somewhere in the striped band, and only the draw knows where."}
        {phase === 1 && "Window over. Drawing the close block from the randomness provider."}
        {phase === 2 && `Revealed. The candle died at block ${revealedClose.toString()}. Orders after it roll forward.`}
      </div>
    </div>
  );
}
