#include <Arduino.h>
#include <Wire.h>

#include <MPU6050.h>

#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>

#define SCREEN_WIDTH   128
#define SCREEN_HEIGHT  64

#define OLED_SDA       21
#define OLED_SCL       22

#define OLED_ADDRESS   0x3C

Adafruit_SSD1306 display(
    SCREEN_WIDTH,
    SCREEN_HEIGHT,
    &Wire,
    -1
);

#define SERVICE_UUID           "12345678-1234-1234-1234-1234567890ab"
#define CHARACTERISTIC_TX_UUID "abcd1234-5678-90ab-cdef-1234567890ab"
#define CHARACTERISTIC_RX_UUID "fedcba98-7654-3210-fedc-ba9876543210"

constexpr uint8_t FLEX_COUNT = 5;

const uint8_t flexPins[FLEX_COUNT] = {32,33,34,35,36};

int flexValues[FLEX_COUNT];

MPU6050 mpu;

int16_t ax, ay, az;
int16_t gx, gy, gz;

BLEServer* pServer = nullptr;

BLECharacteristic* pTxCharacteristic = nullptr;

bool deviceConnected = false;

bool isTransmitting = false;

// BLE send rate = 23Hz
constexpr unsigned long BLE_INTERVAL = 20;

// OLED refresh = 10Hz
constexpr unsigned long OLED_INTERVAL = 100;

unsigned long previousBleMillis  = 0;
unsigned long previousOledMillis = 0;

// ======================================================
// FUNCTION DECLARATIONS

void initOLED();
void initMPU();
void initBLE();
void readSensors();
void sendSensorData();
void updateOLED();

// ======================================================
// BLE SERVER CALLBACKS

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) override {
        deviceConnected = true;
        Serial.println("[BLE] Device Connected");
    }

    void onDisconnect(BLEServer* pServer) override {
        deviceConnected = false;
        isTransmitting = false;
        Serial.println("[BLE] Device Disconnected");
        BLEDevice::startAdvertising();
    }
};

// ======================================================
// BLE RX CALLBACKS

class RXCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pCharacteristic) override {
        std::string value = pCharacteristic->getValue();
        if (value.empty()) return;

        char command = value[0];

        switch (command){
            case 'S':
            {
                isTransmitting = true;
                previousBleMillis = millis();
                Serial.println("[BLE] START TRANSMIT");
                break;
            }

            case 'X':
            {
                isTransmitting = false;
                Serial.println("[BLE] STOP TRANSMIT");
                break;
            }

            default:
            {
                Serial.println("[BLE] UNKNOWN COMMAND");
                break;
            }
        }
    }
};

void setup()
{
    Serial.begin(115200);
    Wire.begin(OLED_SDA, OLED_SCL);
    analogReadResolution(12);

    for (uint8_t i = 0; i < FLEX_COUNT; i++){
        pinMode(flexPins[i], INPUT);
    }

    initOLED();
    initMPU();
    initBLE();
    Serial.println("[SYSTEM] READY");
}

void loop(){
    const unsigned long currentMillis = millis();

    // ==================================================
    // BLE SENSOR STREAM

    if (deviceConnected && isTransmitting){
        if (currentMillis - previousBleMillis >= BLE_INTERVAL){
            previousBleMillis = currentMillis;
            readSensors();
            sendSensorData();
        }
    }

    // ==================================================
    // OLED UPDATE

    if (currentMillis - previousOledMillis >= OLED_INTERVAL){
        previousOledMillis = currentMillis;
        updateOLED();
    }
}

void initOLED()
{
    if (!display.begin(SSD1306_SWITCHCAPVCC,OLED_ADDRESS)){
        Serial.println("[OLED] INIT FAILED");
        while (true);
    }

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(WHITE);
    display.setCursor(0, 0);
    display.println("SYSTEM STARTING...");
    display.display();
    Serial.println("[OLED] READY");
}

void initMPU(){
    mpu.initialize();
    display.clearDisplay();
    display.setCursor(0, 0);

    if (mpu.testConnection()){
        display.println("MPU6050 OK");
        Serial.println("[MPU6050] CONNECTED");
    }else{
        display.println("MPU6050 FAIL");
        Serial.println("[MPU6050] FAILED");
    }

    display.display();
    delay(1000);
}

// ======================================================
// BLE INIT

void initBLE() {
    BLEDevice::init("TRANSLATOR GLOVE");
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());
    BLEService* pService =
        pServer->createService(SERVICE_UUID);

    // ==================================================
    // TX CHARACTERISTIC

    pTxCharacteristic =
        pService->createCharacteristic(
            CHARACTERISTIC_TX_UUID,
            BLECharacteristic::PROPERTY_NOTIFY |
            BLECharacteristic::PROPERTY_READ
        );

    pTxCharacteristic->addDescriptor(
        new BLE2902()
    );

    // ==================================================
    // RX CHARACTERISTIC

    BLECharacteristic* pRxCharacteristic =
        pService->createCharacteristic(
            CHARACTERISTIC_RX_UUID,
            BLECharacteristic::PROPERTY_WRITE
        );

    pRxCharacteristic->setCallbacks(
        new RXCallbacks()
    );

    // ==================================================
    // START SERVICE

    pService->start();

    // ==================================================
    // START ADVERTISING

    BLEAdvertising* pAdvertising =
        BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->setScanResponse(false);
    pAdvertising->setMinPreferred(0x06);
    pAdvertising->setMinPreferred(0x12);
    BLEDevice::startAdvertising();

    Serial.println("[BLE] ADVERTISING STARTED");
}

// ======================================================
// READ SENSORS

void readSensors() {
    for (uint8_t i = 0; i < FLEX_COUNT; i++) {
        flexValues[i] = analogRead(flexPins[i]);
    }

    mpu.getMotion6(
        &ax,&ay,&az,
        &gx,&gy,&gz
    );
}

// ======================================================
// SEND BLE DATA

void sendSensorData(){
    char data[128];

    snprintf(
        data,
        sizeof(data),
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
        flexValues[0],
        flexValues[1],
        flexValues[2],
        flexValues[3],
        flexValues[4],
        ax,ay,az,
        gx,gy,gz
    );

    pTxCharacteristic->setValue(
        (uint8_t*)data,
        strlen(data)
    );

    pTxCharacteristic->notify();
    Serial.print(data);

    delay(3);
}

// ======================================================
// OLED UPDATE

void updateOLED()
{
    display.clearDisplay();
    display.setCursor(0, 0);

    // ==================================================
    // BLE STATUS

    if (deviceConnected) display.println("BLE : CONNECTED");
    else display.println("BLE : WAITING");

    // ==================================================
    // MODE

    if (isTransmitting) display.println("MODE: SENDING");
    else display.println("MODE: IDLE");

    // ==================================================

    display.printf(
        "F1:%4d F2:%4d\n",
        flexValues[0],
        flexValues[1]
    );

    display.printf(
        "F3:%4d F4:%4d\n",
        flexValues[2],
        flexValues[3]
    );

    display.printf(
        "F5:%4d\n",
        flexValues[4]
    );

    display.printf(
        "AX:%5d GX:%5d\n",
        ax, gx
    );

    display.printf(
        "AY:%5d GY:%5d\n",
        ay, gy
    );

    display.printf(
        "AZ:%5d GZ:%5d\n",
        az, gz
    );

    display.display();
}
