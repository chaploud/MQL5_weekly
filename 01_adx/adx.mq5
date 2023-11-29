/* adx.mq5
 * ADXでトレンドに乗る
 */

// USD/JPY 最適化によって足を選択
// バックテストはリアルティックに基づくテストを行うこと

#property copyright "Copyright 2023-11-29 Shota Kudo"
#property version   "1.01"
#property description "ADX EA"

#define ADX_MAGIC 1898549

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Math\Stat\Math.mqh>

// 最適化可能なパラメータ
input int p_leverage = 24;                    // レバレッジ 1～25
input double p_max_level = 0.95;              // 資金使用率
input int p_spread_th = 20;                   // スプレッド閾値
input ENUM_TIMEFRAMES p_period = PERIOD_M20;  // 足
input int p_adx_period = 104;                 // ADXの算出期間
input double p_ts_atr_coef = 7.21;            // トレーリングストップの値幅 ATR*p
input double p_sl_atr_coef = 54.1;            // 最初のSL ATR*p

enum Signal {
  NONE,
  BUY,
  SELL,
};

struct Index {
  double di_p[];
  double di_m[];
  double atr[];
};

// グローバル変数
CSymbolInfo g_symbol;
CTrade g_trade;
CAccountInfo g_account;
datetime g_last_order_time;
Index g_index;
Signal g_signal;
int g_handle_adx;
int g_handle_atr;


// EA起動時に1回呼び出される
void OnInit(void) {
  SendNotification("ADX EA Started!");

  g_symbol.Name(Symbol());
  g_trade.SetExpertMagicNumber(ADX_MAGIC);
  g_last_order_time = TimeCurrent();
  // g_trade.SetAsyncMode(true); // Async注文を有効にする

  // 必要
  ArraySetAsSeries(g_index.di_p, true);
  ArraySetAsSeries(g_index.di_m, true);
  ArraySetAsSeries(g_index.atr, true);

  g_handle_adx = iADX(Symbol(), p_period, p_adx_period);
  g_handle_atr = iATR(Symbol(), p_period, 14);

  g_signal = NONE;
}

// 指標の計算
bool CalcIndex(void) {
  if (CopyBuffer(g_handle_adx, 1, 1, 2, g_index.di_p) != 2) {
    return false;
  }
  if (CopyBuffer(g_handle_adx, 2, 1, 2, g_index.di_m) != 2) {
    return false;
  }
  if (CopyBuffer(g_handle_atr, 0, 1, 1, g_index.atr) != 1) {
    return false;
  }
  return true;
}

// エントリーシグナルの計算
void CalcEntrySignal() {

  // 足が切り替わった瞬間のみ計算される

  if (g_index.di_p[1] < g_index.di_m[1] && g_index.di_p[0] > g_index.di_m[0]) {
    g_signal = BUY;
    return;
  } else if (g_index.di_p[1] > g_index.di_m[1] && g_index.di_p[0] < g_index.di_m[0]) {
    g_signal = SELL;
    return;
  }

  g_signal = NONE;
  return;
}

// ロットの算出
double GetLot(bool fix = false, bool useAll = false) {
  if (fix) {
    return 0.1;
  }

  // アカウント情報の取得
  double margin;
  if (useAll) {
    // 口座残高全部を参照
    margin = g_account.Balance();
  } else {
    // 余剰証拠金を参照
    margin = g_account.FreeMargin();
  }

  double price = iClose(Symbol(), 0, 0);
  double lot = margin * p_leverage / price / 100000 * p_max_level;
  if (lot < 0.1) {
    lot = 0.1;
  } else if (lot > 10) {
    lot = 10;
  }

  lot = NormalizeDouble(lot, 2);
  return lot;
}


// シグナルに応じて売買・修正を行う
void Execute() {

  if (ArraySize(g_index.di_p) < 2) {
    return;
  }

  double atr = g_index.atr[0];

  // ポジション確認
  CPositionInfo position;
  int position_num = 0;

  for (int i = 0; i < PositionsTotal(); i++) {
    if (!position.SelectByIndex(i)) {
      continue;
    }
    if (position.Magic() != ADX_MAGIC) {
      continue;
    }

    ulong ticket = PositionGetTicket(i);
    ENUM_POSITION_TYPE pos_type = position.PositionType();
    double sl_prev = position.StopLoss();
    double sl_buy = g_symbol.Bid() - atr * p_ts_atr_coef;
    double sl_sell = g_symbol.Ask() + atr * p_ts_atr_coef;

    if (pos_type == POSITION_TYPE_BUY) {
      position_num++;
      if (sl_buy > sl_prev && sl_buy > position.PriceOpen()) {
        g_trade.PositionModify(ticket, sl_buy, 0);
      }
      if (g_index.di_p[1] > g_index.di_m[1] && g_index.di_p[0] < g_index.di_m[0]) {
        g_trade.PositionClose(ticket);
        position_num--;
      }
    } else if (pos_type == POSITION_TYPE_SELL) {
      position_num++;
      if (sl_sell < sl_prev && sl_sell < position.PriceOpen()) {
        g_trade.PositionModify(ticket, sl_sell, 0);
      }
      if (g_index.di_p[1] < g_index.di_m[1] && g_index.di_p[0] > g_index.di_m[0]) {
        g_trade.PositionClose(ticket);
        position_num--;
      }
    }
  }

  datetime bar_time[];
  CopyTime(Symbol(), p_period, 0, 1, bar_time);
  if (g_last_order_time == bar_time[0]) {
    return;
  }

  // 新規注文
  // スプレッドが広い時は取引しない
  if (g_symbol.Spread() > p_spread_th) {
    return;
  }

  double lot = GetLot(false, true);

  double sl_buy = g_symbol.Bid() - atr * p_sl_atr_coef;
  double sl_sell = g_symbol.Ask() + atr * p_sl_atr_coef;

  // このマジックナンバーのポジションがあるときは新規注文しない
  if (position_num == 0 && g_signal == BUY) {
    g_trade.Buy(lot, NULL, 0, sl_buy);
    g_last_order_time = bar_time[0];
  } else if (position_num == 0 && g_signal == SELL) {
    g_trade.Sell(lot, NULL, 0, sl_sell);
    g_last_order_time = bar_time[0];
  }
}

// Tickが入るごとに実行される
void OnTick(void) {
  // レート更新
  if (!g_symbol.RefreshRates()) {
    return;
  }

  // 指標の計算
  if (!CalcIndex()) {
    return;
  }

  // シグナルの計算
  CalcEntrySignal();

  // 売買執行
  Execute();
}

// バックテスト最適化用のカスタム指標
double OnTester() {
  double param = 0.0;

  double balance = TesterStatistics(STAT_PROFIT);
  double min_dd = TesterStatistics(STAT_BALANCE_DD);
  if (min_dd > 0.0) {
    min_dd = 1.0 / min_dd;
  }
  double trades_number = TesterStatistics(STAT_TRADES);
  param = balance * min_dd * trades_number;

  return param;
}
