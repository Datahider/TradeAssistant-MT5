//+------------------------------------------------------------------+
//|                                              TradeAssistant.mq5  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//--- Inputs
input double RiskMoney          = 1000.0;
input int    ATRPeriod          = 14;
input double ATRMultiplier      = 2.0;
input int    CloseAfterBars     = 24;
input bool   UseATRTrailing     = true;

//--- Buttons
string BtnSell = "Sell";
string BtnAdd  = "Add";
string BtnBuy  = "Buy";

//--- Service
datetime lastBarTime = 0;


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

   CreateButtons();

   lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   Log("EA started on " + _Symbol);

   if(PositionSelect(_Symbol))
   {
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
   ObjectDelete(0, BtnSell);
   ObjectDelete(0, BtnAdd);
   ObjectDelete(0, BtnBuy);

   Log("EA stopped");
}


//+------------------------------------------------------------------+
void OnTick()
{
   if(IsNewBar())
   {
      Log("New bar");

      if(UseATRTrailing)
         TrailPositionByATR();

      CheckPositionCloseByBars();
   }
}


//+------------------------------------------------------------------+
void OnChartEvent(
   const int id,
   const long &lparam,
   const double &dparam,
   const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   ResetButtonState(sparam);

   if(sparam == BtnBuy)
      OpenTrade(ORDER_TYPE_BUY, "Button Buy");

   if(sparam == BtnSell)
      OpenTrade(ORDER_TYPE_SELL, "Button Sell");

   if(sparam == BtnAdd)
      AddToPosition();
}


//+------------------------------------------------------------------+
void CreateButtons()
{
   CreateButton(BtnSell, 20, 20);
   CreateButton(BtnAdd,  140, 20);
   CreateButton(BtnBuy,  260, 20);
}


//+------------------------------------------------------------------+
void CreateButton(string name,int x,int y)
{
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);

   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);

   ObjectSetInteger(0,name,OBJPROP_XSIZE,110);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,35);

   ObjectSetString(0,name,OBJPROP_TEXT,name);
}


//+------------------------------------------------------------------+
void ResetButtonState(string name)
{
   if(ObjectFind(0, name) < 0)
      return;

   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ChartRedraw();
}


//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, string reason)
{
   if(PositionSelect(_Symbol))
   {
      Log("Trade skipped: position already exists");
      return;
   }

   double atr = GetATR();

   if(atr <= 0)
   {
      Log("Trade skipped: ATR unavailable");
      return;
   }

   double stopDistance = atr * ATRMultiplier;

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double sl = 0;

   if(type == ORDER_TYPE_BUY)
      sl = ask - stopDistance;

   if(type == ORDER_TYPE_SELL)
      sl = bid + stopDistance;

   double lot = CalculateLot(stopDistance);

   if(lot <= 0)
      return;

   bool result = false;

   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(
         lot,_Symbol,ask,sl,0,"ATR Buy"
      );

   if(type == ORDER_TYPE_SELL)
      result = trade.Sell(
         lot,_Symbol,bid,sl,0,"ATR Sell"
      );

   if(result)
   {
      Log(
         "Opened "
         + EnumToString(type)
         + " reason="
         + reason
         + " lot="
         + DoubleToString(lot, GetVolumeDigits())
         + " ATR="
         + DoubleToString(atr,_Digits)
         + " SL="
         + DoubleToString(sl,_Digits)
      );
   }
   else
   {
      Log(
         "Open failed. Retcode="
         + IntegerToString(trade.ResultRetcode())
      );
   }
}


//+------------------------------------------------------------------+
void AddToPosition()
{
   if(!PositionSelect(_Symbol))
   {
      Log("Add skipped: no open position");
      return;
   }

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(POSITION_TYPE);

   double current_volume =
      PositionGetDouble(POSITION_VOLUME);

   double open_price =
      PositionGetDouble(POSITION_PRICE_OPEN);

   double current_sl =
      PositionGetDouble(POSITION_SL);

   if(current_volume <= 0)
   {
      Log("Add skipped: invalid position volume");
      return;
   }

   if(current_sl <= 0)
   {
      Log("Add skipped: stop loss is not set");
      return;
   }

   double price = 0;
   double max_add_lot = 0;

   if(type == POSITION_TYPE_BUY)
   {
      if(current_sl <= open_price)
      {
         Log("Add skipped: current stop loss is not in profit");
         return;
      }

      price = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      max_add_lot = CalculateMaxAddLotBuy(
         current_volume,
         open_price,
         current_sl,
         price
      );
   }

   if(type == POSITION_TYPE_SELL)
   {
      if(current_sl >= open_price)
      {
         Log("Add skipped: current stop loss is not in profit");
         return;
      }

      price = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      max_add_lot = CalculateMaxAddLotSell(
         current_volume,
         open_price,
         current_sl,
         price
      );
   }

   if(max_add_lot <= 0)
   {
      Log("Add skipped: no safe add volume available");
      return;
   }

   double lot = NormalizeVolumeDown(max_add_lot);
   double min_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   if(lot < min_lot)
   {
      Log("Add skipped: safe add volume is below minimal lot");
      return;
   }

   bool result = false;

   if(type == POSITION_TYPE_BUY)
      result = trade.Buy(
         lot,_Symbol,price,current_sl,0,"Add Buy"
      );

   if(type == POSITION_TYPE_SELL)
      result = trade.Sell(
         lot,_Symbol,price,current_sl,0,"Add Sell"
      );

   if(result)
   {
      Log(
         "Added "
         + DoubleToString(lot, GetVolumeDigits())
         + " to "
         + EnumToString(type)
         + " at "
         + DoubleToString(price,_Digits)
         + " with SL="
         + DoubleToString(current_sl,_Digits)
      );
   }
   else
   {
      Log(
         "Add failed. Retcode="
         + IntegerToString(trade.ResultRetcode())
      );
   }
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
   int handle =
      iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(handle == INVALID_HANDLE)
      return 0;

   double buffer[];

   if(CopyBuffer(handle,0,shift,1,buffer) <= 0)
   {
      IndicatorRelease(handle);
      return 0;
   }

   IndicatorRelease(handle);

   return buffer[0];
}


//+------------------------------------------------------------------+
double CalculateLot(double stopDistance)
{
   double tickSize =
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);

   double tickValue =
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
      return 0;

   double riskPerLot =
      (stopDistance / tickSize) * tickValue;

   if(riskPerLot <= 0)
      return 0;

   double lot = RiskMoney / riskPerLot;

   double minLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   double maxLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

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

   volume = MathFloor(volume / step_lot) * step_lot;

   return NormalizeDouble(volume, volume_digits);
}


//+------------------------------------------------------------------+
double CalculateMaxAddLotBuy(
   double current_volume,
   double open_price,
   double current_sl,
   double add_price)
{
   double max_lot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

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
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

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


//+------------------------------------------------------------------+
bool IsNettingAccount()
{
   long margin_mode =
      AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   return margin_mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
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
         Log(
            "Trailing BUY SL "
            + DoubleToString(currentSL,_Digits)
            + " -> "
            + DoubleToString(newSL,_Digits)
         );

         trade.PositionModify(
            _Symbol,newSL,currentTP
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
         Log(
            "Trailing SELL SL "
            + DoubleToString(currentSL,_Digits)
            + " -> "
            + DoubleToString(newSL,_Digits)
         );

         trade.PositionModify(
            _Symbol,newSL,currentTP
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
      Log("Closing by bars limit");
      trade.PositionClose(_Symbol);
   }
}
//+------------------------------------------------------------------+
