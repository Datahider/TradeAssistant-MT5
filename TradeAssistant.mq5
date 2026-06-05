//+------------------------------------------------------------------+
//|                                              TradeAssistant.mq5  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//--- Inputs
input double RiskMoney          = 1000.0;
input double MaxLot             = 0.25;
input int    ATRPeriod          = 14;
input double ATRMultiplier      = 2.0;
input int    CloseAfterBars     = 24;
input bool   UseATRTrailing     = true;

//--- Service
datetime lastBarTime = 0;
int atr_handle = INVALID_HANDLE;
long tracked_position_id = 0;


//+------------------------------------------------------------------+
void Log(string msg)
{
   Print("[TradeAssistant] ", msg);
}


//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsNettingAccount())
   {
      Log("EA supports netting accounts only");
      return(INIT_FAILED);
   }

   atr_handle =
      iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(atr_handle == INVALID_HANDLE)
   {
      Log("Failed to create ATR handle");
      return(INIT_FAILED);
   }

   lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   Log("EA started on " + _Symbol);

   if(PositionSelect(_Symbol))
   {
      tracked_position_id =
         PositionGetInteger(POSITION_IDENTIFIER);

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      datetime openTime =
         (datetime)PositionGetInteger(POSITION_TIME);

      int barsPassed =
         iBarShift(_Symbol, PERIOD_CURRENT, openTime);

      double sl =
         PositionGetDouble(POSITION_SL);

      Log(
         "Found existing position: "
         + EnumToString(type)
         + ", bars passed="
         + IntegerToString(barsPassed)
         + ", SL="
         + DoubleToString(sl,_Digits)
      );
   }
   else
   {
      Log("No open position found");
   }

   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(atr_handle);
      atr_handle = INVALID_HANDLE;
   }

   Log("EA stopped");
}


//+------------------------------------------------------------------+
void OnTick()
{
   MonitorPosition();

   if(IsNewBar())
   {
      Log("New bar");

      if(UseATRTrailing)
         TrailPositionByATR();

      AutoAddToPosition();

      CheckPositionCloseByBars();
   }
}


//+------------------------------------------------------------------+
void MonitorPosition()
{
   if(!PositionSelect(_Symbol))
   {
      tracked_position_id = 0;
      return;
   }

   long current_position_id =
      PositionGetInteger(POSITION_IDENTIFIER);

   if(current_position_id == tracked_position_id)
      return;

   tracked_position_id = current_position_id;
   ProcessNewPosition();
}


//+------------------------------------------------------------------+
void ProcessNewPosition()
{
   double min_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   double current_volume =
      PositionGetDouble(POSITION_VOLUME);

   if(!IsMinimalLotPosition(current_volume, min_lot))
   {
      Log(
         "Auto sizing skipped: position volume="
         + DoubleToString(current_volume, GetVolumeDigits())
      );
      return;
   }

   ENUM_POSITION_TYPE position_type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(POSITION_TYPE);

   ENUM_ORDER_TYPE order_type =
      PositionTypeToOrderType(position_type);

   if(order_type != ORDER_TYPE_BUY
      && order_type != ORDER_TYPE_SELL)
   {
      Log("Auto sizing skipped: unsupported position type");
      return;
   }

   double atr = GetATR();

   if(atr <= 0)
   {
      Log("Auto sizing skipped: ATR unavailable");
      return;
   }

   double stop_distance =
      atr * ATRMultiplier;

   double open_price =
      PositionGetDouble(POSITION_PRICE_OPEN);

   double current_tp =
      PositionGetDouble(POSITION_TP);

   double stop_loss =
      CalculateStopLoss(order_type, open_price, stop_distance);

   if(stop_loss <= 0)
   {
      Log("Auto sizing skipped: failed to calculate stop loss");
      return;
   }

   double target_lot =
      CalculateLot(order_type, open_price, stop_loss);

   if(target_lot <= 0)
      return;

   if(!ModifyPosition(
      "Initial stop setup "
      + DoubleToString(stop_loss,_Digits),
      stop_loss,
      current_tp
   ))
      return;

   double add_lot =
      NormalizeVolumeDown(
         LimitLotByMaximum(target_lot) - current_volume
      );

   if(add_lot < min_lot)
   {
      Log(
         "Auto sizing complete without add: target lot="
         + DoubleToString(target_lot, GetVolumeDigits())
      );
      return;
   }

   AddVolumeToPosition(
      order_type,
      add_lot,
      stop_loss,
      "Initial auto add"
   );
}


//+------------------------------------------------------------------+
void AutoAddToPosition()
{
   if(!PositionSelect(_Symbol))
      return;

   ENUM_POSITION_TYPE position_type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(POSITION_TYPE);

   ENUM_ORDER_TYPE order_type =
      PositionTypeToOrderType(position_type);

   if(order_type != ORDER_TYPE_BUY
      && order_type != ORDER_TYPE_SELL)
      return;

   double current_volume =
      PositionGetDouble(POSITION_VOLUME);

   double open_price =
      PositionGetDouble(POSITION_PRICE_OPEN);

   double current_sl =
      PositionGetDouble(POSITION_SL);

   if(current_volume <= 0 || current_sl <= 0)
      return;

   double max_add_lot = 0;
   double max_allowed_lot =
      GetEffectiveMaxLot();

   if(current_volume >= max_allowed_lot)
      return;

   if(position_type == POSITION_TYPE_BUY)
   {
      if(current_sl <= open_price)
         return;

      double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      max_add_lot = CalculateMaxAddLotBuy(
         current_volume,
         open_price,
         current_sl,
         ask
      );
   }

   if(position_type == POSITION_TYPE_SELL)
   {
      if(current_sl >= open_price)
         return;

      double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);

      max_add_lot = CalculateMaxAddLotSell(
         current_volume,
         open_price,
         current_sl,
         bid
      );
   }

   double add_lot = NormalizeVolumeDown(max_add_lot);
   double remaining_lot =
      NormalizeVolumeDown(max_allowed_lot - current_volume);
   double min_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   if(add_lot > remaining_lot)
      add_lot = remaining_lot;

   if(add_lot < min_lot)
      return;

   AddVolumeToPosition(
      order_type,
      add_lot,
      current_sl,
      "Bar auto add"
   );
}


//+------------------------------------------------------------------+
//| ATR from previous closed bar                                     |
//+------------------------------------------------------------------+
double GetATR()
{
   return GetATRByShift(1);
}


//+------------------------------------------------------------------+
double GetATRByShift(int shift)
{
   if(atr_handle == INVALID_HANDLE)
      return 0;

   double buffer[];

   if(CopyBuffer(atr_handle,0,shift,1,buffer) <= 0)
      return 0;

   return buffer[0];
}


//+------------------------------------------------------------------+
double CalculateLot(
   ENUM_ORDER_TYPE type,
   double entry_price,
   double stop_loss)
{
   double loss_per_lot =
      CalculateLossPerLot(type, entry_price, stop_loss);

   if(loss_per_lot <= 0)
      return 0;

   double lot = RiskMoney / loss_per_lot;

   double minLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   double maxLot =
      GetEffectiveMaxLot();

   double stepLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(minLot <= 0 || maxLot <= 0 || stepLot <= 0)
      return 0;

   if(lot < minLot)
   {
      Log("Trade skipped: minimal lot exceeds risk");
      return 0;
   }

   lot = NormalizeVolumeDown(lot);

   if(lot > maxLot)
      lot = maxLot;

   lot = NormalizeVolumeDown(lot);

   double actual_risk =
      CalculateLossPerLot(type, entry_price, stop_loss, lot);

   if(actual_risk > RiskMoney)
      lot = NormalizeVolumeDown(lot - stepLot);

   if(lot < minLot)
   {
      Log("Trade skipped: minimal lot exceeds risk");
      return 0;
   }

   return lot;
}


//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBar =
      iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      return true;
   }

   return false;
}


//+------------------------------------------------------------------+
int GetVolumeDigits()
{
   double step_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   int digits = 0;

   while(digits < 8)
   {
      double rounded_step =
         NormalizeDouble(step_lot, digits);

      if(MathAbs(rounded_step - step_lot) < 1e-8)
         return digits;

      digits++;
   }

   return 8;
}


//+------------------------------------------------------------------+
double NormalizeVolumeDown(double volume)
{
   double step_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   int volume_digits =
      GetVolumeDigits();

   if(step_lot <= 0)
      return 0;

   if(volume <= 0)
      return 0;

   volume = MathFloor(volume / step_lot) * step_lot;

   return NormalizeDouble(volume, volume_digits);
}


//+------------------------------------------------------------------+
double GetEffectiveMaxLot()
{
   double broker_max_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

   if(broker_max_lot <= 0)
      return 0;

   if(MaxLot <= 0)
      return broker_max_lot;

   if(MaxLot < broker_max_lot)
      return NormalizeVolumeDown(MaxLot);

   return broker_max_lot;
}


//+------------------------------------------------------------------+
double LimitLotByMaximum(double lot)
{
   double max_lot =
      GetEffectiveMaxLot();

   if(max_lot <= 0)
      return 0;

   if(lot > max_lot)
      return max_lot;

   return lot;
}


//+------------------------------------------------------------------+
double CalculateLossPerLot(
   ENUM_ORDER_TYPE type,
   double entry_price,
   double stop_loss,
   double volume = 1.0)
{
   double profit = 0;

   if(volume <= 0)
      return 0;

   if(!OrderCalcProfit(
      type,
      _Symbol,
      volume,
      entry_price,
      stop_loss,
      profit
   ))
   {
      Log("OrderCalcProfit failed");
      return 0;
   }

   if(profit >= 0)
      return 0;

   return -profit;
}


//+------------------------------------------------------------------+
double CalculateMaxAddLotBuy(
   double current_volume,
   double open_price,
   double current_sl,
   double add_price)
{
   double max_lot =
      GetEffectiveMaxLot();

   double free_volume = max_lot - current_volume;

   if(free_volume <= 0)
      return 0;

   double denominator = add_price - current_sl;

   if(denominator <= 0)
      return free_volume;

   double numerator =
      current_volume * (current_sl - open_price);

   if(numerator <= 0)
      return 0;

   double max_add_lot = numerator / denominator;

   if(max_add_lot > free_volume)
      max_add_lot = free_volume;

   return max_add_lot;
}


//+------------------------------------------------------------------+
double CalculateMaxAddLotSell(
   double current_volume,
   double open_price,
   double current_sl,
   double add_price)
{
   double max_lot =
      GetEffectiveMaxLot();

   double free_volume = max_lot - current_volume;

   if(free_volume <= 0)
      return 0;

   double denominator = current_sl - add_price;

   if(denominator <= 0)
      return free_volume;

   double numerator =
      current_volume * (open_price - current_sl);

   if(numerator <= 0)
      return 0;

   double max_add_lot = numerator / denominator;

   if(max_add_lot > free_volume)
      max_add_lot = free_volume;

   return max_add_lot;
}


bool IsNettingAccount()
{
   long margin_mode =
      AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   return margin_mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
}


//+------------------------------------------------------------------+
bool ModifyPosition(string context, double new_sl, double current_tp)
{
   if(trade.PositionModify(_Symbol, new_sl, current_tp))
   {
      Log(context + " applied");
      return true;
   }

   Log(
      context
      + " failed. Retcode="
      + IntegerToString(trade.ResultRetcode())
   );

   return false;
}


//+------------------------------------------------------------------+
bool ClosePosition(string context)
{
   if(trade.PositionClose(_Symbol))
   {
      Log(context + " applied");
      return true;
   }

   Log(
      context
      + " failed. Retcode="
      + IntegerToString(trade.ResultRetcode())
   );

   return false;
}


//+------------------------------------------------------------------+
bool AddVolumeToPosition(
   ENUM_ORDER_TYPE order_type,
   double lot,
   double stop_loss,
   string context)
{
   double price = 0;
   bool result = false;

   if(order_type == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      result = trade.Buy(
         lot,_Symbol,price,stop_loss,0,context
      );
   }

   if(order_type == ORDER_TYPE_SELL)
   {
      price = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      result = trade.Sell(
         lot,_Symbol,price,stop_loss,0,context
      );
   }

   if(result)
   {
      Log(
         context
         + " applied lot="
         + DoubleToString(lot, GetVolumeDigits())
         + " price="
         + DoubleToString(price,_Digits)
         + " SL="
         + DoubleToString(stop_loss,_Digits)
      );
      return true;
   }

   Log(
      context
      + " failed. Retcode="
      + IntegerToString(trade.ResultRetcode())
   );

   return false;
}


//+------------------------------------------------------------------+
bool IsMinimalLotPosition(double volume, double min_lot)
{
   if(volume <= 0 || min_lot <= 0)
      return false;

   double step_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(step_lot <= 0)
      return false;

   return MathAbs(volume - min_lot) < (step_lot / 10.0);
}


//+------------------------------------------------------------------+
ENUM_ORDER_TYPE PositionTypeToOrderType(
   ENUM_POSITION_TYPE position_type)
{
   if(position_type == POSITION_TYPE_BUY)
      return ORDER_TYPE_BUY;

   if(position_type == POSITION_TYPE_SELL)
      return ORDER_TYPE_SELL;

   return WRONG_VALUE;
}


//+------------------------------------------------------------------+
double CalculateStopLoss(
   ENUM_ORDER_TYPE order_type,
   double entry_price,
   double stop_distance)
{
   if(order_type == ORDER_TYPE_BUY)
      return entry_price - stop_distance;

   if(order_type == ORDER_TYPE_SELL)
      return entry_price + stop_distance;

   return 0;
}


//+------------------------------------------------------------------+
void TrailPositionByATR()
{
   if(!PositionSelect(_Symbol))
      return;

   double atr = GetATR();

   if(atr <= 0)
      return;

   double stopDistance =
      atr * ATRMultiplier;

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(POSITION_TYPE);

   double currentSL =
      PositionGetDouble(POSITION_SL);

   double currentTP =
      PositionGetDouble(POSITION_TP);

   double bid =
      SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double ask =
      SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   double newSL = 0;

   if(type == POSITION_TYPE_BUY)
   {
      newSL = bid - stopDistance;

      if(currentSL == 0 || newSL > currentSL)
      {
         ModifyPosition(
            "Trailing BUY SL "
            + DoubleToString(currentSL,_Digits)
            + " -> "
            + DoubleToString(newSL,_Digits),
            newSL,
            currentTP
         );
      }
      else
      {
         Log("Trailing skipped BUY");
      }
   }

   if(type == POSITION_TYPE_SELL)
   {
      newSL = ask + stopDistance;

      if(currentSL == 0 || newSL < currentSL)
      {
         ModifyPosition(
            "Trailing SELL SL "
            + DoubleToString(currentSL,_Digits)
            + " -> "
            + DoubleToString(newSL,_Digits),
            newSL,
            currentTP
         );
      }
      else
      {
         Log("Trailing skipped SELL");
      }
   }
}


//+------------------------------------------------------------------+
void CheckPositionCloseByBars()
{
   if(!PositionSelect(_Symbol))
      return;

   datetime openTime =
      (datetime)
      PositionGetInteger(POSITION_TIME);

   int barsPassed =
      iBarShift(
         _Symbol,
         PERIOD_CURRENT,
         openTime
      );

   Log(
      "Position age: "
      + IntegerToString(barsPassed)
      + "/"
      + IntegerToString(CloseAfterBars)
      + " bars"
   );

   if(barsPassed >= CloseAfterBars)
   {
      ClosePosition("Closing by bars limit");
   }
}
//+------------------------------------------------------------------+
