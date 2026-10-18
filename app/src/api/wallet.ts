import { rpc } from './client';

export interface WithdrawResult {
  id: string;
  amount: number;
  fee: number;
  payout: number;
  balance: number;
}

// Request a withdrawal. Server enforces the 1% fee (min 1 point) and returns the net payout.
export function requestWithdrawal(amount: number, esewaId: string, esewaName: string) {
  return rpc<WithdrawResult>('request_withdrawal', {
    p_amount: amount,
    p_esewa_id: esewaId,
    p_esewa_name: esewaName,
  });
}

// Client-side preview of the fee so the UI can show "you receive" before submitting.
export function withdrawalPreview(amount: number) {
  const fee = amount >= 1 ? Math.max(1, Math.ceil(amount / 100)) : 0;
  return { fee, receive: Math.max(0, amount - fee) };
}
