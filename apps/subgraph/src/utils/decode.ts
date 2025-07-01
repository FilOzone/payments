import { Bytes, Address, BigInt } from "@graphprotocol/graph-ts";

// Enum for supported ABI types
export enum AbiType {
  STRING,
  ADDRESS,
  BOOL,
  BYTES,
  UINT256,
  INT256,
}

// Generic result class that can hold any decoded value
export class AbiValue {
  type: AbiType;
  stringValue: string;
  addressValue: Address;
  boolValue: boolean;
  bytesValue: Bytes;
  uint256Value: BigInt;

  constructor(type: AbiType) {
    this.type = type;
    this.stringValue = "";
    this.addressValue = Address.zero();
    this.boolValue = false;
    this.bytesValue = Bytes.empty();
    this.uint256Value = BigInt.zero();
  }

  static fromString(value: string): AbiValue {
    let result = new AbiValue(AbiType.STRING);
    result.stringValue = value;
    return result;
  }

  static fromAddress(value: Address): AbiValue {
    let result = new AbiValue(AbiType.ADDRESS);
    result.addressValue = value;
    return result;
  }

  static fromBool(value: boolean): AbiValue {
    let result = new AbiValue(AbiType.BOOL);
    result.boolValue = value;
    return result;
  }

  static fromBytes(value: Bytes): AbiValue {
    let result = new AbiValue(AbiType.BYTES);
    result.bytesValue = value;
    return result;
  }

  static fromUint256(value: BigInt): AbiValue {
    let result = new AbiValue(AbiType.UINT256);
    result.uint256Value = value;
    return result;
  }
}

// Specific result classes for common patterns
export class SetOperatorApprovalParams {
  tokenAddress: Address;
  operatorAddress: Address;
  approved: boolean;
  rateAllowance: BigInt;
  lockupAllowance: BigInt;
  maxLockupPeriod: BigInt;

  constructor(
    tokenAddress: Address,
    operatorAddress: Address,
    approved: boolean,
    rateAllowance: BigInt,
    lockupAllowance: BigInt,
    maxLockupPeriod: BigInt
  ) {
    this.tokenAddress = tokenAddress;
    this.operatorAddress = operatorAddress;
    this.approved = approved;
    this.rateAllowance = rateAllowance;
    this.lockupAllowance = lockupAllowance;
    this.maxLockupPeriod = maxLockupPeriod;
  }
}

export class CreateRailParams {
  tokenAddress: Address;
  fromAddress: Address;
  toAddress: Address;
  arbiterAddress: Address;
  commissionRateBps: BigInt;

  constructor(
    tokenAddress: Address,
    fromAddress: Address,
    toAddress: Address,
    arbiterAddress: Address,
    commissionRateBps: BigInt
  ) {
    this.tokenAddress = tokenAddress;
    this.fromAddress = fromAddress;
    this.toAddress = toAddress;
    this.arbiterAddress = arbiterAddress;
    this.commissionRateBps = commissionRateBps;
  }
}

export class BytesStringResult {
  bytesValue: Bytes;
  stringValue: string;

  constructor(bytesValue: Bytes, stringValue: string) {
    this.bytesValue = bytesValue;
    this.stringValue = stringValue;
  }
}

/**
 * Generic ABI decoder that can handle various type combinations
 * @param data - The ABI-encoded bytes
 * @param types - Array of ABI types in order
 * @returns Array of AbiValue objects
 */
export function decodeAbi(data: Bytes, types: AbiType[]): AbiValue[] {
  if (types.length == 0) {
    return [];
  }

  const headerSize = types.length * 32;
  if (data.length < headerSize) {
    throw new Error("Insufficient data length for ABI decoding");
  }

  let results: AbiValue[] = [];
  let dynamicDataOffsets: number[] = [];

  // First pass: read header and collect offsets for dynamic types
  for (let i = 0; i < types.length; i++) {
    const slotStart = i * 32;
    const slot = data.subarray(slotStart, slotStart + 32);

    if (isDynamicType(types[i])) {
      // For dynamic types, read the offset
      const offset = bytesTonumber(slot);
      dynamicDataOffsets.push(offset);
      results.push(new AbiValue(types[i])); // Placeholder
    } else {
      // For static types, decode directly
      results.push(decodeStaticType(slot, types[i]));
      dynamicDataOffsets.push(0); // Not used for static types
    }
  }

  // Second pass: decode dynamic data
  for (let i = 0; i < types.length; i++) {
    if (isDynamicType(types[i])) {
      const offset = dynamicDataOffsets[i];
      results[i] = decodeDynamicType(data, offset, types[i]);
    }
  }

  return results;
}

/**
 * Convenience function for setOperatorApproval
 */
export function decodeSetOperatorApprovalCalldata(
  data: Bytes
): SetOperatorApprovalParams {
  const types: AbiType[] = [
    AbiType.ADDRESS,
    AbiType.ADDRESS,
    AbiType.BOOL,
    AbiType.UINT256,
    AbiType.UINT256,
    AbiType.UINT256,
  ];
  const results = decodeAbi(data, types);

  return new SetOperatorApprovalParams(
    results[0].addressValue,
    results[1].addressValue,
    results[2].boolValue,
    results[3].uint256Value,
    results[4].uint256Value,
    results[5].uint256Value
  );
}

/**
 * Convenience function for setRailPaymentRate
 */
export function decodeCreateRailCalldata(data: Bytes): CreateRailParams {
  const types: AbiType[] = [
    AbiType.ADDRESS,
    AbiType.ADDRESS,
    AbiType.ADDRESS,
    AbiType.ADDRESS,
    AbiType.UINT256,
  ];
  const results = decodeAbi(data, types);

  return new CreateRailParams(
    results[0].addressValue,
    results[1].addressValue,
    results[2].addressValue,
    results[3].addressValue,
    results[4].uint256Value
  );
}

/**
 * Helper function to check if a type is dynamic
 */
function isDynamicType(type: AbiType): boolean {
  return type == AbiType.STRING || type == AbiType.BYTES;
}

/**
 * Decode static types directly from a 32-byte slot
 */
function decodeStaticType(slot: Uint8Array, type: AbiType): AbiValue {
  switch (type) {
    case AbiType.ADDRESS:
      const addressBytes = slot.subarray(12, 32); // Last 20 bytes
      return AbiValue.fromAddress(
        Address.fromBytes(Bytes.fromUint8Array(addressBytes))
      );

    case AbiType.BOOL:
      return AbiValue.fromBool(slot[31] != 0);

    case AbiType.UINT256:
    case AbiType.INT256:
      return AbiValue.fromUint256(
        BigInt.fromUnsignedBytes(changetype<Bytes>(slot))
      );

    default:
      throw new Error("Unsupported static type");
  }
}

/**
 * Decode dynamic types from their data location
 */
function decodeDynamicType(
  data: Bytes,
  offset: number,
  type: AbiType
): AbiValue {
  switch (type) {
    case AbiType.STRING:
      return AbiValue.fromString(decodeDynamicString(data, offset));

    case AbiType.BYTES:
      return AbiValue.fromBytes(decodeDynamicBytes(data, offset));

    default:
      throw new Error("Unsupported dynamic type");
  }
}

/**
 * Converts a 32-byte big-endian array to number
 * Only uses the last 4 bytes to avoid overflow
 */
function bytesTonumber(bytes: Uint8Array): number {
  if (bytes.length != 32) {
    throw new Error("Expected 32 bytes for offset conversion");
  }

  // Use only the last 4 bytes to avoid overflow
  const result =
    (Number(bytes[28]) << 24) |
    (Number(bytes[29]) << 16) |
    (Number(bytes[30]) << 8) |
    Number(bytes[31]);

  return result;
}

/**
 * Decodes a dynamic string from the given offset
 */
function decodeDynamicString(data: Bytes, offset: number): string {
  if (offset + 32 > data.length) {
    throw new Error("String offset exceeds data length");
  }

  // Read length from the first 32 bytes at offset
  const lengthSlot = data.subarray(offset, offset + 32);
  const length = bytesTonumber(lengthSlot);

  // If length is 0, return empty string
  if (length == 0) {
    return "";
  }

  // Read the string data
  const dataStart = offset + 32;
  if (dataStart + length > data.length) {
    throw new Error("String data exceeds available bytes");
  }

  const stringBytes = data.subarray(dataStart, dataStart + length);
  return stringBytes.toString();
}

/**
 * Decodes dynamic bytes from the given offset
 */
function decodeDynamicBytes(data: Bytes, offset: number): Bytes {
  if (offset + 32 > data.length) {
    throw new Error("Bytes offset exceeds data length");
  }

  // Read length from the first 32 bytes at offset
  const lengthSlot = data.subarray(offset, offset + 32);
  const length = bytesTonumber(lengthSlot);

  // If length is 0, return empty bytes
  if (length == 0) {
    return Bytes.fromHexString("0x");
  }

  // Read the bytes data
  const dataStart = offset + 32;
  if (dataStart + length > data.length) {
    throw new Error("Bytes data exceeds available bytes");
  }

  const bytesData = data.subarray(dataStart, dataStart + length);
  return Bytes.fromUint8Array(bytesData);
}
