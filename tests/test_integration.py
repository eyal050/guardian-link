"""
End-to-end integration tests.

These tests require a live Azure environment — they hit real Azure services
and verify the full pipeline from device message to Cosmos DB record.

Run with:
    pytest tests/ --integration

Prerequisites (set via environment variables or .env):
    AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET (or use az login)
    IOTHUB_CONNECTION_STRING (device-scope connection string for sim-01)
    COSMOS_ENDPOINT
    COSMOS_DATABASE  (default: guardianlink)
    COSMOS_CONTAINER (default: telemetry)

The tests use a dedicated device identity (integration-test-device) that
must be registered in IoT Hub before running.
"""

import os
import pytest


# ---------------------------------------------------------------------------
# Telemetry path: device → IoT Hub → Event Hubs → telemetry-writer → Cosmos
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_telemetry_message_reaches_cosmos(tmp_path):
    """
    Send one telemetry message from the simulator, then poll Cosmos DB
    for up to 30 seconds until the telemetry-writer function persists it.

    Verifies:
    - IoT Hub accepts the message (no exception from the SDK)
    - Event Hubs consumer group receives it (implicit: telemetry-writer trigger)
    - Cosmos DB contains a document with the expected device_id and offset
    """
    pytest.skip("Integration test not yet wired to live environment — implement with real IoT Hub connection string")


# ---------------------------------------------------------------------------
# Alert path: crash_suspect → classifier → Service Bus → notifier
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_crash_suspect_triggers_notification():
    """
    Send a crash_suspect event with high accelerometer values. Poll the
    Cosmos DB notifications container for up to 60 seconds until a
    notification record with status=completed appears.

    Verifies:
    - Classifier picks up the event and scores it above threshold
    - Service Bus crash-confirmed queue receives the message
    - Notifier writes a completed notification record to Cosmos DB
    """
    pytest.skip("Integration test not yet wired to live environment — implement after notifier is deployed")


# ---------------------------------------------------------------------------
# Observability: verify App Insights receives custom events
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_app_insights_receives_crash_confirmed_event():
    """
    After test_crash_suspect_triggers_notification, query App Insights
    via the Log Analytics API for a customEvents record with name=crash_confirmed_published.

    Verifies the metrics pipeline emits the expected custom event.
    """
    pytest.skip("Integration test not yet wired — requires Log Analytics query API credentials")
