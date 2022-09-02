import { Card, Flex, Button, Image, ThemeUIStyleObject } from "theme-ui";
import { EventType, HorizontalTimeline, UNKNOWN_DATE } from "../../../HorizontalTimeline";
import { nfts } from "../../context/BondViewProvider";
import { Record } from "../../Record";
import { Actions } from "./actions/Actions";
import {
  BLusdAmmTokenIndex,
  OptimisticBond as OptimisticBondType,
  SwapPressedPayload
} from "../../context/transitions";
import { Label, SubLabel } from "../../../HorizontalTimeline";
import * as l from "../../lexicon";
import { useBondView } from "../../context/BondViewContext";

const getBondEvents = (bond: OptimisticBondType): EventType[] => {
  return [
    {
      date: new Date(bond.startTime),
      label: (
        <>
          <Label description="bLUSD accrual starts off at 0 and increases over time.">
            {l.BOND_CREATED.term}
          </Label>
          <SubLabel>{`0.00 bLUSD`}</SubLabel>
        </>
      )
    },
    {
      date: new Date(Date.now()),
      label: (
        <>
          <Label description={l.ACCRUED_AMOUNT.description} style={{ fontWeight: 500 }}>
            {l.ACCRUED_AMOUNT.term}
          </Label>
          <SubLabel style={{ fontWeight: 400 }}></SubLabel>
        </>
      ),
      isSelected: true
    },
    {
      date: UNKNOWN_DATE,
      label: (
        <>
          <Label description="How many bLUSD are required to break-even at the current market price.">
            {l.BREAK_EVEN_TIME.term}
          </Label>
          <SubLabel style={{ fontWeight: 400 }}></SubLabel>
        </>
      )
    },
    {
      date: UNKNOWN_DATE,
      label: (
        <>
          <Label description="How many bLUSD are recommended before claiming the bond, selling the bLUSD for LUSD, and then opening another bond.">
            {l.OPTIMUM_REBOND_TIME.term}
          </Label>
          <SubLabel style={{ fontWeight: 400 }}></SubLabel>
        </>
      )
    }
  ];
};

type BondProps = { bond: OptimisticBondType; style?: ThemeUIStyleObject };

export const OptimisticBond: React.FC<BondProps> = ({ bond, style }) => {
  const events = getBondEvents(bond);
  const { dispatchEvent } = useBondView();

  const handleSellBLusdPressed = () => {
    dispatchEvent("SWAP_PRESSED", { inputToken: BLusdAmmTokenIndex.BLUSD } as SwapPressedPayload);
  };

  return (
    <Flex
      sx={{
        justifyContent: "center",
        alignItems: "center",
        gap: "12px",
        ...style
      }}
    >
      <Flex>
        {bond.status === "PENDING" && (
          <Image
            sx={{ height: 200, cursor: "pointer", borderRadius: 12 }}
            src={nfts[bond.status]}
            alt="TODO"
            onClick={() => {
              window.open("https://opensea.io", "_blank");
            }}
          />
        )}
        {bond.status === "CANCELLED" && (
          <>
            <Image sx={{ width: 148, cursor: "pointer", borderRadius: 12 }} src={nfts.PENDING} />
            <Image
              sx={{
                width: 148,
                cursor: "pointer",
                borderRadius: "50%",
                backgroundColor: "transparent",
                ml: -148,
                p: "28px"
              }}
              src={nfts[bond.status]}
              alt="TODO"
              onClick={() => {
                window.open("https://opensea.io", "_blank");
              }}
            />
          </>
        )}
        {bond.status === "CLAIMED" && (
          <>
            <Image sx={{ width: 148, cursor: "pointer", borderRadius: 12 }} src={nfts.PENDING} />
            <Image
              sx={{
                width: 148,
                cursor: "pointer",
                borderRadius: "50%",
                backgroundColor: "transparent",
                ml: -148,
                p: "28px"
              }}
              src={nfts[bond.status]}
              alt="TODO"
              onClick={() => {
                window.open("https://opensea.io", "_blank");
              }}
            />
          </>
        )}
      </Flex>
      <Card mt={[0, 0, 0, 0]} sx={{ borderRadius: 12, flexGrow: 1 }}>
        <Flex p={[2, 3]} sx={{ flexDirection: "column" }}>
          <HorizontalTimeline
            style={{ fontSize: "14.5px", justifyContent: "center", pt: 2, mx: 3 }}
            events={events}
          />

          <Flex mt={4} variant="layout.actions" sx={{ justifyContent: "flex-end" }}>
            <Flex
              sx={{
                justifyContent: "flex-start",
                flexGrow: 1,
                alignItems: "center",
                pl: 4,
                gap: "0 28px",
                fontSize: "14.5px"
              }}
            >
              <Record
                name={l.BOND_DEPOSIT.term}
                value={bond.deposit.prettify(2)}
                type="LUSD"
                description={l.BOND_DEPOSIT.description}
              />
              {bond.status === "PENDING" && (
                <Record
                  name={l.MARKET_VALUE.term}
                  type="LUSD"
                  description={l.MARKET_VALUE.description}
                />
              )}
            </Flex>
            {bond.status === "PENDING" && <Actions bondId={bond.id} disabled />}
            {bond.status !== "PENDING" && bond.status === "CLAIMED" && (
              <Button variant="outline" sx={{ height: "44px" }} onClick={handleSellBLusdPressed}>
                Sell bLUSD
              </Button>
            )}
          </Flex>
        </Flex>
      </Card>
    </Flex>
  );
};